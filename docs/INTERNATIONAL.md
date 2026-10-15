# 海外展開の設計（保留） / Archived international plan

2026-10-16追記：海外向けの機能追加は保留しました。以下は2026-10-15時点の調査・検討履歴で、現在の実装予定や提供機能ではありません。国内のシフト入力と給与記録を優先します。[現在の方針](PRODUCT_DECISION.md)

海外向けの通貨・給与モデルは未実装です。

## 対象と売り

日本と同じく、本人が自分のシフトと稼ぎを確認する個人向けアプリにします。海外では「フリーター」の直訳を使わず、**students and hourly workers** と表現します。最初はカフェ・飲食・小売の勤務を持ち、スマートフォンや紙に自分の予定を記録している人に絞ります。複数の勤務先を持つ人も対象です。

英語のメッセージは **Add your shifts. Look forward to payday.**。ホームで稼ぎを確認する体験、給料日の動き、ワンタップ追加を組み合わせて見せます。想定する短い説明は **Shift & Pay Tracker**。App Storeの名前・検索語の競合調査や登録可否を確認した名称ではありません。

最初の海外テストは英国の英語利用者を第一候補にします。英国が最も利益を出せるという調査結果はありません。英語一言語で試用を進め、対象を狭めるための仮説です。英国で協力者を見つけられず、米国などで具体的な試用希望を得られた場合は、その市場を先にします。国名の順位より、実際の対象者に触ってもらえる経路を優先します。

米国・カナダ・オーストラリアを含む配信は次の候補です。初期の通貨設定はJPY・GBP・USD・CAD・AUDを想定しますが、通貨を選べることと、その国の給与制度を自動計算できることは別です。

## 競合から分かること

2026-10-15に一次情報を確認しました。インストール数からこのアプリの売上を予測せず、古いレビューを現行の欠点として扱いません。

| 製品 | 公式に掲載された機能・課金 | この計画への意味 |
| --- | --- | --- |
| [Supershift](https://www.supershift.app/) | テンプレート、繰り返し勤務、給与・時間の集計、共有、ウィジェット。Proのサブスクと買い切りを[FAQ](https://www.supershift.app/help.html)に掲載 | テンプレートや見た目だけを独占的な特徴と呼べない。既存の方法より簡単かを実際に比べる |
| [MyShiftPlanner Pro Pack](https://myshiftplanner.com/pro-pack) | カレンダー連携、共有、複数カレンダー、給与日設定。月次・週次などの給料日に対応。[FAQ](https://myshiftplanner.com/faqs)に月額・年額を掲載 | 給料日の演出を海外へ持ち出すには、月払い以外の支給周期も必要 |
| [HoursTracker / US App Store](https://apps.apple.com/us/app/hours-tracker-time-tracking/id336456412) | 複数の仕事、勤務時間・賃金、チップ、日次・週次の残業、複数の給与周期、出力。無料とアプリ内課金 | 時給の記録と給与確認には既存の代替がある。「海外なら自然に売れる」とは考えない |

各社の有料利用者数、売上、広告獲得費用は確認できていません。この調査だけでこのアプリへの有料需要があるとは言えません。

## 現在の実装で不足している点

| 項目 | 現在の根拠 | 必要な変更 |
| --- | --- | --- |
| 言語 | [英語の文字列](../ShiftManagerApp/ShiftManagerApp/en.lproj/Localizable.strings)と[設定](../ShiftManagerApp/ShiftManagerApp/SettingsView.swift)。一部の動的文章やエラーは日本語 | 英語で初回設定→勤務登録→ホーム→給料記録まで完結させる。通知・エラー・Plus・問い合わせも確認 |
| 通貨・小数 | [Formatting.swift](../ShiftManagerApp/ShiftManagerApp/Formatting.swift)の`yen()`が¥・日本ロケール・整数丸めで固定。勤務概要や勤務先フォームにも整数化あり | ISO通貨コードを保存し、小数と地域の数値入力を扱う。言語を変えても記録の通貨を変えない |
| 支給周期 | [PayPeriod.swift](../PayrollEngine/Sources/PayrollEngine/PayPeriod.swift)は月の締め日・支給月・支給日で計算 | 月次に加えて週次・2週ごとを、基準日と支給日から生成。月2回払いは2週ごとと別モデルにする |
| 給与ルール | [Models.swift](../PayrollEngine/Sources/PayrollEngine/Models.swift)の固定時間帯・割増初期値、[PayCalculation.swift](../PayrollEngine/Sources/PayrollEngine/PayCalculation.swift)の日本向け判定 | 日本向けと、本人が設定した勤務条件から見込額を出す汎用モードを分ける |
| 税・祝日 | [PayPeriod.swift](../PayrollEngine/Sources/PayrollEngine/PayPeriod.swift)の日本の祝日、[WageTab.swift](../ShiftManagerApp/ShiftManagerApp/WageTab.swift)の日本の税額表、[IncomeWallView.swift](../ShiftManagerApp/ShiftManagerApp/IncomeWallView.swift)の年収の壁 | 日本の自動計算を海外に適用しない。海外版の初期提供は見込み総支給と本人が記録した実入金額を中心にする |
| 写真取り込み | [ShiftImport.swift](../PayrollEngine/Sources/PayrollEngine/ShiftImport.swift)は年月日順などを解析し、AM/PMを拒否。[ShiftPhotoReader.swift](../ShiftManagerApp/ShiftManagerApp/ShiftPhotoReader.swift)は日英OCR | 月日・日月を利用者の地域から明示して解析。曖昧な日付を推測しない。12時間表記を対象者の原本で確認 |
| 紹介・サポート | 画面素材・詳細資料は日本語。公開用の連絡先はダミー | 英語紹介、実際の英語画面、利用可能なサポート先、公開版のデータ説明を整える |

これはソースの確認結果です。英語設定での全画面操作や、海外の利用者による試用の確認結果ではありません。

## 初期版の仕様

言語、通貨、給与ルールの地域は独立した設定にします。英語で日本の仕事を管理する人に日本向け給与計算を使える状態を残します。

最初の海外版では1アカウントに1通貨を設定します。為替換算や異なる通貨の合算は追加しません。既存記録はJPYとして保持し、通貨変更で過去の¥1,000を£1,000に読み替えません。通貨を変更する前に記録の扱いを決める移行設計が必要です。

勤務先ごとの給与条件は、時給、休憩、支給周期、基準日、支給日を中心にします。割増を設定する場合も、地域の法定ルールを網羅した自動判定という表示は使わず、適用条件と計算内訳を本人が確認できるようにします。日次・週次判定や日本の祝日による支給日移動が汎用モードに残らないことを確認します。チップは、対象者から必要と分かった場合に別の手当として扱えるか検討します。

ホームの見た目・テンプレート・給料日の演出は維持します。給料日の判定と残高予測は新しい支給周期を同じ仕組みから参照し、入金の二重計上を防ぎます。

## 進める順番

1. **紹介と募集の準備**：英語READMEと説明文を用意。英語圏の対象者5〜10人との試用を目標に、協力者を探す。紹介だけを見た反応と、実操作を分けて記録する。
2. **海外で操作できる最小版**：通貨・小数、給与モードの分離、週次・2週ごとの給料日、主要導線の英語を実装。日本の記録を保つ。
3. **実際の給与周期で確認**：自分の次の勤務を記録してもらい、登録時間、テンプレート再利用、2回目の利用、入金日の一致、現在の方法を置き換えたかを確認する。
4. **Plusの検証**：現地通貨の価格候補を見せ、残高予測・勤務の増減比較・写真一括登録のどれに支払い理由があるか聞く。購入意思と実際の購入は別で扱う。
5. **配信**：対応を確認した国と英語のストア情報・画面素材を用意して公開。利用・購入・問い合わせを国別に観察してから追加地域を決める。

初期の5〜10人は不具合と利用理由を探る規模で、市場規模や利益を推計するサンプルではありません。期間中に対象者を見つけられなければ、機能追加より募集経路の見直しを優先します。

App Storeの配信地域の設定と、ストア情報の言語追加は別作業です。[配信地域](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/manage-availability-for-your-app-on-the-app-store)・[ストア情報のローカライズ](https://developer.apple.com/help/app-store-connect/manage-app-information/localize-app-information)を準備します。現時点ではApp Store Connectに設定を行っていません。

## 英語の試用案内と質問（送信していない下書き）

> I'm building an iPhone app for students and hourly workers to track their shifts and pay. It combines quick shift templates, a clear earnings dashboard, and a small payday animation. It's still in development. Would you be open to a short preview and telling me how you currently keep track of your shifts?

プレビューの時点で日本語画面・JPYしか用意できなければ、その制約を先に伝えます。海外対応版が使えると約束しません。

- How do you currently keep track of your shifts and expected pay?
- How often are you paid, and does that vary between jobs?
- Which part of your current method takes the most effort?
- After seeing the preview, which part would you actually use for your next shift?
- What would have to be better for you to replace your current method?

利用できる版を配布した後は、次の給与周期の終わりに再利用と入金日の表示を確認します。コミュニティへの投稿は各場所の募集・宣伝ルールを確認してから行います。この資料から募集投稿や個別メッセージは送信していません。

## 実装時の確認条件

- 英語と日本語で、勤務先登録、テンプレート追加、給料記録、残高予測、Plus表示、エラーを確認。
- GBP/USD等の小数入力・編集・表示・同期・出力で端数を失わない。通貨に合う金額表現を使う。
- 週次・2週ごとの月跨ぎ、年跨ぎ、うるう日、日付とタイムゾーン変更、深夜跨ぎを確認。
- 月2回払いを2週周期に変換しない。給料日、ホーム、予測で同じ支給日と期間を参照。
- 日本の既存記録、税の設定、月締め給与、給料日移動の結果を維持。
- 読み取りの月日・日月、AM/PMの確認、曖昧な日付の拒否を確認。
- 英語の実画面を取得して紹介素材を更新。日本語画面を英語対応済みの証拠にしない。
