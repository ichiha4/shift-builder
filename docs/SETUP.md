# セットアップ

## ローカルの画面・購入テスト

1. `python3 scripts/setup_local_demo.py` を実行します。
2. `ShiftManagerApp/ShiftManagerApp.xcodeproj` をXcodeで開きます。
3. `ShiftManagerApp-LocalDevice` SchemeとiPhoneシミュレータを選び、Runします。
4. StoreKit Configurationは `ShiftBuilderPlus.storekit` を使います。商品が空の場合は設定を確認して「商品情報を再読み込み」を使い、Xcodeから再実行します。

データはこのアプリのUserDefaultsに保存され、通常のクラウド版とは分離されています。アプリを削除するとデモデータも消えます。本番への移行機能はありません。

## 自分のiPhone

無料のApple AccountをXcodeに登録し、iPhoneを接続して信頼と開発者モードの設定を済ませます。アプリ・テストのBundle IDを自分用に変更し、LocalDevice構成のSigning & Capabilitiesで自分のPersonal Teamを選びます。個人のTeam IDは公開ソースには設定していません。

無料署名には有効期限などの制限があります。[Appleの無料アカウント案内](https://developer.apple.com/help/account/basics/about-your-developer-account)。本プロジェクトでは実機へのインストールと購入の通し確認は未完了です。

## Firebaseを使う通常版

自分のFirebaseプロジェクトを用意してiOSアプリを登録し、対応する `GoogleService-Info.plist` を `ShiftManagerApp/ShiftManagerApp/` に置きます。`Info.plist` のURL schemeも自分のREVERSED_CLIENT_IDに変更します。GoogleログインとAppleログインの設定、Bundle ID、署名、Firestoreルールの反映は各自の環境に合わせる必要があります。設定ファイルはGitの対象外です。

公開用コピーのサポート・プライバシーのリンクはこのリポジトリを参照します。実際に配信するときは、自分のサービスの公開窓口とポリシーに差し替えてください。

## Firestoreルールのローカルテスト

Node.jsとFirebase Emulatorに必要なJavaを用意します。

```sh
cd release-tests
npm ci
npx firebase emulators:exec --project demo-shiftbuilder-sync --only firestore "npm test"
```

このコマンドは `demo-` 接頭辞のテスト用プロジェクトとローカルエミュレータを使用します。iOSのFirestoreテストは認証エミュレータも必要です。通常のPlusTests Schemeで `SHIFTBUILDER_EMULATOR_TESTS=1` を指定して実行します。
