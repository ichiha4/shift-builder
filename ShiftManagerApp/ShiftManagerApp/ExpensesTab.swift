import SwiftUI

struct ExpensesTab: View {
    @EnvironmentObject var store: ShiftStore
    @Environment(\.locale) private var locale
    @Binding var month: String

    @State private var date = Date()
    @State private var category = PayrollConstants.expenseCategories[0]
    @State private var amountText = ""
    @State private var memo = ""
    @State private var error: String?
    @State private var showRecurringExpenses = false
    /// Deleting asks first — the trash button sits in the same row as the record it removes, and
    /// there is no undo behind it.
    @State private var pendingDelete: Expense?
    @FocusState private var amountFocused: Bool

    private var monthExpenses: [Expense] {
        store.expenses.filter { $0.date.hasPrefix(month) }.sorted { $0.date < $1.date }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    monthNav
                    addForm
                    recurringCard
                    listCard
                }
                .padding(16)
                .readableColumn()
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("支出").font(.title2.weight(.bold))
                }
            }
            .onAppear { alignEntryDate(); store.generateDueRecurringExpenses() }
            .onChange(of: month) { _, _ in alignEntryDate() }
            .confirmationDialog(
                "この支出を削除しますか?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { expense in
                Button("削除", role: .destructive) { store.deleteExpense(id: expense.id) }
                Button("キャンセル", role: .cancel) {}
            } message: { expense in
                Text("\(NSLocalizedString(expense.category, comment: ""))・\(yen(expense.amount))")
            }
        }
    }

    private func alignEntryDate() {
        guard !DateUtils.ymd(date).hasPrefix(month) else { return }
        let today = DateUtils.todayYMD()
        if today.hasPrefix(month) { date = Date(); return }
        if let (y, m, d) = DateUtils.parseYMD(month + "-01") {
            date = DateUtils.date(year: y, month: m, day: d)
        }
    }

    private var monthNav: some View {
        HStack {
            Button { month = DateUtils.shiftMonth(month, by: -1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel("前の月")
            Spacer()
            Text(DateUtils.monthLabel(month, locale: locale)).font(.headline)
            Spacer()
            Button { month = DateUtils.shiftMonth(month, by: 1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel("次の月")
        }
        .padding(.horizontal, 8)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader("支出を追加", systemImage: "plus.circle")

            DatePicker("日付", selection: $date, displayedComponents: .date)

            Picker("カテゴリ", selection: $category) {
                ForEach(PayrollConstants.expenseCategories, id: \.self) { cat in
                    Label {
                        Text(LocalizedStringKey(cat))
                    } icon: {
                        Circle().fill(expenseCategoryColors[cat] ?? .gray).frame(width: 10, height: 10)
                    }
                    .tag(cat)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("金額(円)").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text("¥").foregroundStyle(.secondary)
                    TextField("0", text: $amountText)
                        .keyboardType(.numberPad)
                        .font(.title3.weight(.semibold))
                        .focused($amountFocused)
                }
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: AppStyle.controlRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppStyle.controlRadius, style: .continuous)
                        .stroke(amountFocused ? Color.accentColor : Color.clear, lineWidth: 2)
                )
            }

            TextField("メモ(任意)", text: $memo)
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: AppStyle.controlRadius, style: .continuous))

            if let error { Text(error).font(.caption).foregroundStyle(.red) }

            // Accent, not green: green means "money in" everywhere else in this app (pay, net
            // totals), so a green primary button on the expense form read as the wrong direction.
            Button {
                submit()
            } label: {
                Label("支出を追加", systemImage: "plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
        }
        .appCard()
    }

    private var recurringCard: some View {
        Button {
            showRecurringExpenses = true
        } label: {
            // A plain navigation row rather than the old centred, green-outlined panel: it leads
            // to another screen like any other row, and the outline gave it more visual weight
            // than the form above it, which is the screen's actual primary action.
            HStack(spacing: 12) {
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("サブスク管理").font(.subheadline).fontWeight(.semibold)
                    Text(store.recurringExpenses.isEmpty
                         ? LocalizedStringKey("毎月自動で発生する支出を登録できます")
                         : LocalizedStringKey("\(store.recurringExpenses.count)件登録中"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appCard()
        .sheet(isPresented: $showRecurringExpenses) {
            RecurringExpensesView().environmentObject(store)
        }
    }

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader("この月の支出") {
                if !monthExpenses.isEmpty {
                    Text("−" + yen(monthExpenses.reduce(0) { $0 + $1.amount }))
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundStyle(.red)
                }
            }
            if monthExpenses.isEmpty {
                Text("まだ記録がありません。").font(.caption).foregroundStyle(.secondary)
            } else {
                // Note: `.swipeActions` only works inside a `List` — this screen uses a plain
                // ScrollView (to keep the custom card styling), so delete is a visible button.
                ForEach(monthExpenses) { expense in
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(expenseCategoryColors[expense.category] ?? .gray)
                            .frame(width: 4)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(LocalizedStringKey(expense.category)).fontWeight(.semibold)
                                Spacer()
                                Text("−" + yen(expense.amount)).foregroundStyle(.red).fontWeight(.semibold)
                            }
                            Text(expense.date.suffix(5) + (expense.memo.isEmpty ? "" : " ・ " + expense.memo))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            pendingDelete = expense
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                                .padding(10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("支出を削除")
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .appCard()
    }

    private func submit() {
        guard let amount = Double(amountText), amount.isFinite, amount > 0 else {
            error = "金額を入力してください"
            return
        }
        error = nil
        store.addExpense(Expense(date: DateUtils.ymd(date), category: category, amount: amount, memo: memo))
        month = String(DateUtils.ymd(date).prefix(7))
        amountText = ""
        memo = ""
    }
}
