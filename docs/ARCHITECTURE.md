# 設計と実装

## 構成

```text
ShiftManagerApp/
  ShiftManagerApp/             SwiftUI画面、認証、通知、同期、以前の試作
  ShiftManagerAppPlusTests/    iOSロジック・以前のStoreKit/OCRのテスト
  ShiftManagerApp.xcodeproj/   通常・PlusTests・LocalDeviceの共有Scheme
PayrollEngine/
  Sources/PayrollEngine/      給与・支給期間・給与記録の集計、同期モデル、以前の試作
  Tests/PayrollEngineTests/   独立したロジックのテスト
release-tests/               Firestoreルールのエミュレータテスト
firestore.rules             アカウント単位のアクセスと同期書き込みの検証
```

## 現在の通常導線

`ContentView` はホーム・シフト・給与の3タブです。ホームからも日付選択へつなぎ、`ShiftsTab.quickAdd` が選択日で再生成した勤務を検証・保存します。テンプレートは勤務履歴のパターンから生成し、保存時にも既存勤務との時間重複を再確認します。

ホームは今日を基準にした翌月の支給分を `PayPeriod.shifts(paidInMonth:)` で抽出します。勤務先未登録の勤務は給料日を推測して含めません。給与画面は選択した支給月を使い、複数の締め期間が休日調整で同月に入る場合も扱います。

`ShiftStore.deleteShiftWithUndo` は通常の削除を即時保存し、元のシフトを5秒だけメモリに保持します。連続削除は同じ復元対象に加えて期限を延長します。`undoShiftDeletions` は全件を検証してから1回の編集で復元し、ID・金額・休憩などを保持します。追加済みの同一IDを上書きせず、新しい勤務との重複があれば全件を戻さずに知らせます。期限切れとアカウント解除時に復元候補を消します。

## 給与計算と実績の分離

日跨ぎ・休憩・残業・勤務先条件の計算処理をFoundationベースのSwiftパッケージに置きます。ホームの金額は登録した勤務から計算する控除前の見込みです。

実績は `ActualPayment` に支給日と勤務先を持ち、`taxableGross`（明細から入力する課税支給額）と `amount`（任意の手取り）を区別します。以前の `amount` だけのデータも復号できます。旧記録を課税支給額に変換しません。現在の保存は勤務先・支給日で更新するため、同じ給与を編集しても二重計上しません。

`Aggregation.recordedIncome` は支給済みの給与明細だけを暦年で集計します。将来支給日とシフト見込みを除外し、同じ勤務先・支給日の重複は後の記録を採用します。`RecordedIncomeWallCard` は本人が設定した年間上限との差を表示します。上限は端末に保存し、ログアウト・データ消去時に消去します。健康保険の扶養資格などの判定には使いません。

## 同期

`ShiftStore` と `CloudSyncTransport` の境界で、Firestoreとローカルデモの保存処理を切り替えます。アカウントごとのローカル状態、未反映の編集、リビジョン、反映済み編集の識別子を扱います。オフライン編集・再送・競合を管理し、削除済みアカウントに古い編集が戻らないようにします。

通常構成はFirebase認証を必要とします。`LOCAL_DEVICE_TESTING` はDebug専用で、Firebase初期化とログインを省き、別のBundle ID・保存領域で動きます。

## 保留した試作

残高予測・勤務増減比較・Apple Vision写真取り込み・StoreKit 2課金・詳細な年収予測のソースとテストは残していますが、通常画面の入口は外しました。アプリ起動時に `SubscriptionManager` を生成・商品取得しません。写真取り込みの精度改善や海外向け給与制度の追加は現在の範囲に含めません。

予測用のキャッシュフロー処理にも、課税支給額を実際の手取り入金として扱わせない分離を残しています。
