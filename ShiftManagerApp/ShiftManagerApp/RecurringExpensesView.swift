import SwiftUI

/// Manage fixed monthly outgoings (subscriptions, rent, etc.). Once saved, `ShiftStore`
/// auto-generates a matching `Expense` for the current month as soon as `dayOfMonth` is
/// reached — this screen only manages the recurring template itself.
struct RecurringExpensesView: View {
    @EnvironmentObject var store: ShiftStore
    @Environment(\.dismiss) private var dismiss

    @State private var showAddSheet = false
    @State private var editingItem: RecurringExpense?

    var body: some View {
        NavigationStack {
            Group {
                if store.recurringExpenses.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.trianglehead.2.clockwise")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("サブスクはまだ登録されていません")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("サブスクや家賃など、毎月自動で発生する支出を登録できます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.recurringExpenses) { item in
                            Button {
                                editingItem = item
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(item.name).fontWeight(.semibold).foregroundStyle(.primary)
                                            if !item.isActive {
                                                Text("停止中").font(.caption2).foregroundStyle(.secondary)
                                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                                    .background(Color(.tertiarySystemFill))
                                                    .clipShape(Capsule())
                                            }
                                        }
                                        (Text(LocalizedStringKey(item.category))
                                            + Text(item.dayOfMonth == 0 ? "・末日に発生" : "・\(item.dayOfMonth)日に発生"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("−" + yen(item.amount)).foregroundStyle(.red).fontWeight(.semibold)
                                }
                            }
                        }
                        .onDelete { indices in
                            for index in indices { store.deleteRecurringExpense(id: store.recurringExpenses[index].id) }
                        }
                    }
                }
            }
            .navigationTitle("サブスク管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .tint(.green)
                }
            }
            .sheet(isPresented: $showAddSheet) {
                RecurringExpenseFormView(existing: nil).environmentObject(store)
            }
            .sheet(item: $editingItem) { item in
                RecurringExpenseFormView(existing: item).environmentObject(store)
            }
        }
    }
}

private struct RecurringExpenseFormView: View {
    @EnvironmentObject var store: ShiftStore
    @Environment(\.dismiss) private var dismiss

    let existing: RecurringExpense?

    @State private var name: String
    @State private var category: String
    @State private var amountText: String
    @State private var memo: String
    @State private var dayOfMonth: Int
    @State private var isActive: Bool
    @State private var error: String?

    init(existing: RecurringExpense?) {
        self.existing = existing
        if let item = existing {
            _name = State(initialValue: item.name)
            _category = State(initialValue: item.category)
            _amountText = State(initialValue: String(Int(item.amount)))
            _memo = State(initialValue: item.memo)
            _dayOfMonth = State(initialValue: item.dayOfMonth)
            _isActive = State(initialValue: item.isActive)
        } else {
            _name = State(initialValue: "")
            _category = State(initialValue: PayrollConstants.expenseCategories[0])
            _amountText = State(initialValue: "")
            _memo = State(initialValue: "")
            _dayOfMonth = State(initialValue: 1)
            _isActive = State(initialValue: true)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例:Netflix", text: $name)
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
                    LabeledContent("金額(円)") {
                        TextField("0", text: $amountText).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    Picker("発生日", selection: $dayOfMonth) {
                        Text("末日").tag(0)
                        ForEach(1...31, id: \.self) { Text("\($0)日").tag($0) }
                    }
                    Toggle("有効", isOn: $isActive)
                } header: {
                    Text("サブスク")
                } footer: {
                    Text("毎月この日になると、自動的に支出として記録されます。")
                }

                Section {
                    TextField("メモ(任意)", text: $memo)
                }

                if let error {
                    Section { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle(existing == nil ? "サブスクを追加" : "サブスクを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "追加" : "更新") { save() }
                        .tint(.green)
                }
            }
        }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            error = "名称を入力してください"
            return
        }
        guard let amount = Double(amountText), amount > 0 else {
            error = "金額を入力してください"
            return
        }
        error = nil
        store.saveRecurringExpense(RecurringExpense(
            id: existing?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespaces),
            category: category,
            amount: amount,
            memo: memo,
            dayOfMonth: dayOfMonth,
            isActive: isActive
        ))
        dismiss()
    }
}

#Preview {
    RecurringExpensesView().environmentObject(ShiftStore())
}
