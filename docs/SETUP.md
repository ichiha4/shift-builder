# セットアップ

## ローカルの画面確認

1. `python3 scripts/setup_local_demo.py` を実行します。
2. `ShiftManagerApp/ShiftManagerApp.xcodeproj` をXcodeで開きます。
3. `ShiftManagerApp-LocalDevice` SchemeとiPhoneシミュレータを選び、Runします。
4. シフト画面の「テンプレートを作成」で勤務先・時間・時給を保存します。カレンダーで勤務する日を選び、テンプレートをタップして追加します。
5. 給与画面で給与明細の課税支給額を入力し、ホームの年収カードから自分の年間上限を設定します。

現在の通常画面はサブスク登録を使いません。既存のStoreKit設定・購入テストは、以前の試作を検証するための履歴として残しています。

データはこのアプリのUserDefaultsに保存され、通常のクラウド版とは分離されています。アプリを削除するとデモデータも消えます。本番への移行機能はありません。

## 自分のiPhone

無料のApple AccountをXcodeに登録し、iPhoneを接続して信頼と開発者モードの設定を済ませます。アプリ・テストのBundle IDを自分用に変更し、LocalDevice構成のSigning & Capabilitiesで自分のPersonal Teamを選びます。個人のTeam IDは公開ソースには設定していません。

無料署名には有効期限などの制限があります。[Appleの無料アカウント案内](https://developer.apple.com/help/account/basics/about-your-developer-account)。本プロジェクトでは実機での通し確認は未完了です。

## Firebaseを使う通常版

自分のFirebaseプロジェクトを用意してiOSアプリを登録し、対応する `GoogleService-Info.plist` を `ShiftManagerApp/ShiftManagerApp/` に置きます。`Info.plist` のURL schemeも自分のREVERSED_CLIENT_IDに変更します。GoogleログインとAppleログインの設定、Bundle ID、署名、Firestoreルールの反映は各自の環境に合わせる必要があります。設定ファイルはGitの対象外です。

公開用コピーのサポート・プライバシー・利用規約のリンクはこのリポジトリを参照します。実際に配信するときは、自分のサービスの公開窓口とポリシー・利用条件に差し替えてください。設定画面とログイン画面のリンクは `SupportInfo` の同じURLを参照します。問い合わせ用メールアドレスもダミーから差し替えてください。

## Firestoreルールのローカルテスト

Node.jsとJava 21を用意し、リポジトリのルートで実行します。

```sh
npm --prefix release-tests ci
./release-tests/node_modules/.bin/firebase emulators:exec \
  --project demo-shiftbuilder-sync --config firebase.emulators.json \
  --only firestore "npm --prefix release-tests test"
```

このコマンドは `demo-` 接頭辞のテスト用プロジェクトとローカルエミュレータを使用します。iOSのFirestoreテストは認証エミュレータも必要です。通常のPlusTests Schemeで `SHIFTBUILDER_EMULATOR_TESTS=1` を指定して実行します。

本番配布前に、接続する端末を現在の同期方式へ更新してから `firestore.rules` を反映します。新ルールは旧方式の全体上書きを拒否し、テンプレートを残したアカウント削除も拒否します。エミュレータでの成功は本番反映を意味しません。
