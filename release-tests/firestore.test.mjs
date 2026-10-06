import { before, after, beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { initializeTestEnvironment, assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { doc, setDoc, getDoc, deleteDoc, runTransaction, increment } from 'firebase/firestore';
let env;
const uid = 'owner';
const blank = () => ({shifts:[],expenses:[],employerProfiles:[],deductions:[],actualPayments:[],recurringExpenses:[],_syncSchema:1,_syncRevision:1,_recentMutations:[],_accountDeleted:false});
const db = (user=uid, auth_time=Math.floor(Date.now()/1000)) => env.authenticatedContext(user,{auth_time}).firestore();
const ref = (client, user=uid) => doc(client,'users',user);
async function seed(data) { await env.withSecurityRulesDisabled(c=>setDoc(ref(c.firestore()),data)); }
before(async()=>{ env=await initializeTestEnvironment({projectId:'demo-shiftbuilder-sync',firestore:{host:'127.0.0.1',port:8085,rules:await readFile(new URL('../firestore.rules',import.meta.url),'utf8')}}); });
after(async()=>{await env.cleanup()});
beforeEach(async()=>{await env.clearFirestore()});
test('unauthenticated and other users cannot read or write',async()=>{
 await seed(blank()); const anon=env.unauthenticatedContext().firestore(), other=db('other');
 await assertFails(getDoc(ref(anon))); await assertFails(setDoc(ref(anon),blank()));
 await assertFails(getDoc(ref(other))); await assertFails(setDoc(ref(other),blank()));
 await assertSucceeds(getDoc(ref(db())));
});
test('owner can create and commit the next revision',async()=>{
 const client=db(); await assertSucceeds(setDoc(ref(client),blank()));
 await assertSucceeds(setDoc(ref(client),{...blank(),_syncRevision:2,shifts:[{id:'a'}]}));
});
test('legacy whole-account replacement cannot erase new sync metadata or history',async()=>{
 await seed({...blank(),shifts:[{id:'keep'}]}); const client=db();
 await assertFails(setDoc(ref(client),{shifts:[],expenses:[],employerProfiles:[],deductions:[]}));
 assert.equal((await getDoc(ref(client))).data().shifts[0].id,'keep');
});
test('stale revision and malformed arrays are rejected',async()=>{
 await seed(blank()); const client=db();
 await assertFails(setDoc(ref(client),{...blank(),_syncRevision:1}));
 await assertFails(setDoc(ref(client),{...blank(),_syncRevision:2,expenses:'broken'}));
 await assertFails(setDoc(ref(client),{...blank(),_syncRevision:2,_syncSchema:2}));
});
test('account deletion clears all six arrays and retains a marker',async()=>{
 await seed({...blank(),shifts:[{id:'a'}]}); const client=db();
 await assertFails(setDoc(ref(client),{...blank(),_syncRevision:2,_accountDeleted:true,_deletionToken:'token',shifts:[{id:'a'}]}));
 await assertSucceeds(setDoc(ref(client),{...blank(),_syncRevision:2,_accountDeleted:true,_deletionToken:'token'}));
 await assertFails(deleteDoc(ref(client)));
});
test('stale session cannot recreate deleted account; fresh matching rollback can',async()=>{
 await seed({...blank(),_syncRevision:2,_accountDeleted:true,_deletionToken:'token'});
 const old=db(uid,Math.floor(Date.now()/1000)-600), fresh=db();
 await assertFails(setDoc(ref(old),{...blank(),_syncRevision:3,_deletionToken:'token',shifts:[{id:'a'}]}));
 await assertFails(setDoc(ref(fresh),{...blank(),_syncRevision:3,_deletionToken:'wrong'}));
 await assertFails(setDoc(ref(fresh),{...blank(),_syncRevision:3}));
 await assertSucceeds(setDoc(ref(fresh),{...blank(),_syncRevision:3,_deletionToken:'token',shifts:[{id:'a'}]}));
});
// Use two independent clients and real emulator transactions to exercise Firestore retries.
async function add(client,id) {
 return runTransaction(client,async tx=>{
  const r=ref(client), state=(await tx.get(r)).data() ?? {...blank(),_syncRevision:0};
  if(state._accountDeleted) throw new Error('deleted');
  tx.set(r,{...state,shifts:[...state.shifts,{id}],_syncRevision:increment(1)},{merge:true});
 });
}
test('concurrent transactions retain both devices additions',async()=>{
 await seed(blank()); await Promise.all([add(db(),'a'),add(db(),'b')]);
 const data=(await getDoc(ref(db()))).data(); assert.deepEqual(new Set(data.shifts.map(x=>x.id)),new Set(['a','b'])); assert.equal(data._syncRevision,3);
});
test('transaction with deleted marker cannot publish cached records',async()=>{
 await seed({...blank(),_accountDeleted:true,_deletionToken:'token'});
 await assert.rejects(add(db(),'stale')); assert.deepEqual((await getDoc(ref(db()))).data().shifts,[]);
});
test('single transaction with server increment is accepted',async()=>{
 await seed(blank()); await add(db(),'single'); assert.equal((await getDoc(ref(db()))).data()._syncRevision,2);
});

test('simultaneous first account creation retains both devices records',async()=>{
 await Promise.all([add(db(),'first-a'),add(db(),'first-b')]);
 const data=(await getDoc(ref(db()))).data(); assert.deepEqual(new Set(data.shifts.map(x=>x.id)),new Set(['first-a','first-b'])); assert.equal(data._syncRevision,2);
});
