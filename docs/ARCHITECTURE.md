# 設計と実装

## 構成

```text
ShiftManagerApp/
  ShiftManagerApp/             SwiftUI画面、認証、通知、同期、OCR、課金
  ShiftManagerAppPlusTests/    iOSロジックとStoreKitのテスト
  ShiftManagerApp.xcodeproj/   通常・PlusTests・LocalDeviceの共有Scheme
PayrollEngine/
  Sources/PayrollEngine/      給与計算、給料日、残高予測、取り込み検証、同期モデル
  Tests/PayrollEngineTests/   独立したロジックのテスト
release-tests/               Firestoreルールのエミュレータテスト
firestore.rules             アカウント単位のアクセスと同期書き込みの検証
```

## 給与計算と表示の分離

画面から独立したFoundationベースの計算処理をSwiftパッケージに置きます。日付をまたぐ勤務、休憩、週をまたぐ残業、勤務先の給与条件を集計に反映します。収入比較では、シフトを増減した仮定を再計算し、保存済みの勤務データは変更しません。

残高予測は、入力された残高から翌日以降の給料日と定期支出を計算します。銀行残高の取得や手取り額の自動確定は行いません。未入力の生活費や同日内の入出金順序は予測に含まれません。

## 同期

`ShiftStore` と `CloudSyncTransport` の境界により、Firestoreとローカルデモ用の保存処理を切り替えます。アカウントごとのローカル状態、未反映の編集、リビジョン、反映済み編集の識別子を扱い、オフライン編集や再送に備えます。競合を画面に表示し、削除済みアカウントに古い編集が戻らないように処理します。Firestoreルールにも所有者・スキーマ・リビジョンの検証を置きます。

## 写真取り込み

PhotosPickerで選択した画像をApple Visionで処理します。個人用一覧から日付・時間・休憩の候補を作り、利用者が対象月と勤務先を選び、原本と照合して修正します。画像やOCR文字列を保存レコードには含めません。全候補を検証して1件の編集として保存し、同じ勤務先・日付・時刻の再登録を避けます。

## 課金とデモの分離

`SubscriptionManager` はStoreKit 2の検証済みの購入情報からPlusを判断します。ローカル保存のフラグで有料機能を解放しません。`LOCAL_DEVICE_TESTING` はDebug専用で、Firebaseの初期化とログインを省いて、別のBundle ID・保存領域で実行します。この構成はXcode環境の購入情報だけを受け付けます。本番の課金設定・Sandbox確認は別途必要です。
