# 保守ガイド

どの機能をどのファイルで直すかの対応表です。設計の背景は `docs/ARCHITECTURE.md` を参照してください。

## 編集先の対応表

| 直したいもの | 編集するファイル |
| --- | --- |
| タブの構成、同期中・読み込み失敗の表示 | `ShiftManagerApp/ShiftManagerApp/ContentView.swift` |
| ホームの来月の給与予定カード・グラフ・次のシフト・勤務先別 | `OverviewTab.swift` |
| 給料日のお知らせカード、`PaydayPrompt` | `PaydayBanner.swift` |
| 給与明細（課税支給額・任意の手取り）の入力・削除シート | `ActualPaySheet.swift` |
| シフト画面のカレンダー連動・テンプレートのタップ追加・重複確認・削除の取り消し | `ShiftsTab.swift` |
| テンプレート管理一覧（編集・削除） | `TemplateManagerView.swift` |
| シフトの入力フォーム（手入力・編集・テンプレート作成） | `ShiftFormView.swift` |
| カレンダー表示 | `CalendarMonthView.swift` |
| 給与タブ（支給月・給料日・記録した給与・控除） | `WageTab.swift` |
| 給与明細の詳細（時間内訳・所得税・週ごとの労働時間） | `WageDetailView.swift` |
| 年収の壁カード・上限設定（記録した給与明細ベース） | `RecordedIncomeWallView.swift` |
| 以前の年収予測の試作、`IncomeWallSettings` のキー | `IncomeWallView.swift` |
| 勤務先の登録・一覧 | `EmployerProfileFormView.swift`、`EmployerProfilesView.swift` |
| 給与・支給期間・集計の計算 | `PayrollEngine/Sources/PayrollEngine/` |

## 境界

- **画面（SwiftUI）**: 表示と、本人の操作を `ShiftStore` の処理に渡すことだけを担当します。金額の計算式や保存形式を画面側に持たせません。
- **`ShiftStore`**: 記録の保存・同期・取り消し・重複確認後の保存を担当します。保存キー・同期のリビジョン・ジャーナルはここと `CloudSyncTransport` の内側にあり、画面の分割では触りません。
- **`PayrollEngine`**: Foundationだけに依存する計算処理です。画面から呼ぶ入口は `Aggregation`・`PayPeriod`・`Validation` などで、テストは `PayrollEngine/Tests` にあります。

## 守ること

- ホームは画面で選んだ月ではなく、**今日を基準にした翌月**の支給分を表示します（`OverviewTab.paymentMonth`）。
- シフトの見込み（控除前）と、給与明細から入力した課税支給額・任意の手取りは別の値として扱います。
- 新しいSwiftファイルは `ShiftManagerApp.xcodeproj/project.pbxproj` に手動で登録します（PBXFileReference・PBXBuildFile・グループ・アプリのSourcesフェーズ）。フォルダの自動検出は使っていません。
- `ShiftsTab` の `ShiftFormat` と `TemplateManagerView` は、ファイルをまたいで使うため `private` ではなく内部（internal）のアクセスにしています。
