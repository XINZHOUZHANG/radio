import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var session: TX5DRSession
    @State private var showingCreate = false
    @State private var pairingCode: MobilePairingCodeResponse?
    @State private var pendingDelete: AuthTokenInfo?
    @State private var pendingRegenerate: AuthTokenInfo?
    @State private var editingAccount: AuthTokenInfo?
    @State private var revealedToken: CreateAccountResponse?

    var body: some View {
        List {
            Section {
                Button {
                    Task { pairingCode = await session.createPairingCode() }
                } label: {
                    Label("生成 6 位一次性配对码", systemImage: "rectangle.and.hand.point.up.left.filled")
                }
                if let pairingCode {
                    PairingCodeCard(pairing: pairingCode)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            } header: {
                Text("iOS 配对")
            } footer: {
                Text("验证码有效期 2 分钟、只能使用一次，并受服务端速率限制。")
            }

            Section("账户") {
                ForEach(session.accounts) { account in
                    HStack(spacing: 12) {
                        Image(systemName: account.role == .admin ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                            .foregroundStyle(account.revoked ? RadioPalette.muted : RadioPalette.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.label)
                            HStack(spacing: 7) {
                                Text(account.loginCredential?.username ?? "仅令牌")
                                Text(roleName(account.role))
                                if account.system == true { Text("系统") }
                            }
                            .font(.caption)
                            .foregroundStyle(RadioPalette.muted)
                        }
                        Spacer()
                        if account.id == session.currentUser?.tokenId {
                            Text("当前")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(RadioPalette.cyan)
                        }
                        Menu {
                            Button {
                                editingAccount = account
                            } label: {
                                Label("编辑账户", systemImage: "pencil")
                            }

                            if account.system == true {
                                Button(role: .destructive) {
                                    pendingRegenerate = account
                                } label: {
                                    Label("重新生成系统令牌", systemImage: "arrow.triangle.2.circlepath")
                                }
                            } else if account.id != session.currentUser?.tokenId {
                                Button(role: .destructive) {
                                    pendingDelete = account
                                } label: {
                                    Label("撤销账户", systemImage: "trash")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if account.id != session.currentUser?.tokenId, account.system != true {
                            Button(role: .destructive) { pendingDelete = account } label: {
                                Label("撤销", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("账户与配对")
        .toolbar {
            Button { showingCreate = true } label: { Image(systemName: "person.badge.plus") }
        }
        .task { await session.refreshAccounts() }
        .refreshable { await session.refreshAccounts() }
        .sheet(isPresented: $showingCreate) { CreateAccountView() }
        .sheet(item: $editingAccount) { account in
            EditAccountView(account: account)
        }
        .sheet(item: $revealedToken) { token in
            TokenRevealView(account: token)
        }
        .confirmationDialog(
            "撤销账户？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("撤销", role: .destructive) {
                if let pendingDelete { Task { await session.deleteAccount(pendingDelete) } }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("该账户的令牌与用户名密码将立即失效。")
        }
        .confirmationDialog(
            "重新生成系统令牌？",
            isPresented: Binding(
                get: { pendingRegenerate != nil },
                set: { if !$0 { pendingRegenerate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("重新生成", role: .destructive) {
                guard let account = pendingRegenerate else { return }
                pendingRegenerate = nil
                Task { revealedToken = await session.regenerateSystemAccount(account) }
            }
            Button("取消", role: .cancel) { pendingRegenerate = nil }
        } message: {
            Text("旧系统令牌会立即失效。新令牌只显示一次，请先准备好安全的保存位置。")
        }
    }

    private func roleName(_ role: UserRole) -> String {
        switch role {
        case .admin: "管理员"
        case .operator: "操作员"
        case .viewer: "观察员"
        }
    }
}

private struct EditAccountView: View {
    @EnvironmentObject private var session: TX5DRSession
    @Environment(\.dismiss) private var dismiss

    let account: AuthTokenInfo

    @State private var label: String
    @State private var role: UserRole
    @State private var selectedOperators: Set<String>
    @State private var maxOperators: Int
    @State private var allowSelfService: Bool
    @State private var credentialEnabled: Bool
    @State private var username: String
    @State private var password = ""
    @State private var saving = false

    init(account: AuthTokenInfo) {
        self.account = account
        _label = State(initialValue: account.label)
        _role = State(initialValue: account.role == .viewer ? .operator : account.role)
        _selectedOperators = State(initialValue: Set(account.operatorIds))
        _maxOperators = State(initialValue: max(1, account.maxOperators ?? 1))
        _allowSelfService = State(initialValue: account.allowSelfLoginCredential ?? false)
        _credentialEnabled = State(initialValue: account.loginCredential != nil)
        _username = State(initialValue: account.loginCredential?.username ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("账户") {
                    TextField("显示名称", text: $label)
                    Picker("角色", selection: $role) {
                        Text("操作员").tag(UserRole.operator)
                        Text("管理员").tag(UserRole.admin)
                    }
                    if role == .operator {
                        Stepper("同时可用操作员：\(maxOperators)", value: $maxOperators, in: 1...32)
                    }
                }

                if role == .operator {
                    Section("可用操作员") {
                        ForEach(session.operators) { item in
                            Button {
                                if selectedOperators.contains(item.id) {
                                    selectedOperators.remove(item.id)
                                } else {
                                    selectedOperators.insert(item.id)
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.myCallsign)
                                            .foregroundStyle(Color.primary)
                                        Text(item.id)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(RadioPalette.muted)
                                    }
                                    Spacer()
                                    if selectedOperators.contains(item.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(RadioPalette.accent)
                                    }
                                }
                            }
                        }
                    } footer: {
                        Text("至少选择一个操作员；最大并发数不能超过此列表数量。")
                    }
                }

                Section {
                    Toggle("启用用户名和密码登录", isOn: $credentialEnabled)
                    if credentialEnabled {
                        TextField("用户名（3–32 位）", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField(
                            account.loginCredential == nil ? "密码（至少 8 位）" : "新密码（留空则不修改）",
                            text: $password
                        )
                    }
                    Toggle("允许用户自行修改登录密码", isOn: $allowSelfService)
                } header: {
                    Text("登录凭据")
                } footer: {
                    if !credentialEnabled, account.loginCredential != nil {
                        Text("保存后将删除现有用户名与密码；应急令牌仍然有效。")
                    } else {
                        Text("关闭用户名密码登录不会改变应急令牌权限。")
                    }
                }

                if account.id == session.currentUser?.tokenId {
                    Section {
                        Label("你正在编辑当前登录账户。降低权限或移除当前操作员可能导致本次会话失去部分能力。", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(RadioPalette.warning)
                    }
                }
            }
            .navigationTitle("编辑账户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中" : "保存") { save() }
                        .disabled(!valid || saving)
                }
            }
        }
    }

    private var valid: Bool {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let roleIsValid = role == .admin || !selectedOperators.isEmpty
        let credentialIsValid = !credentialEnabled
            || (trimmedUsername.count >= 3
                && trimmedUsername.count <= 32
                && (password.isEmpty ? account.loginCredential != nil : password.count >= 8))
        return !trimmedLabel.isEmpty && roleIsValid && credentialIsValid
    }

    private func save() {
        let trimmedPassword = password.isEmpty ? nil : password
        let request = UpdateAccountRequest(
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            role: role,
            operatorIds: role == .admin ? [] : Array(selectedOperators),
            maxOperators: role == .admin ? 0 : min(maxOperators, max(1, selectedOperators.count)),
            allowSelfLoginCredential: allowSelfService,
            permissionGrants: role == .operator ? account.permissionGrants : nil,
            loginCredential: credentialEnabled
                ? .init(
                    username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: trimmedPassword
                )
                : nil,
            clearLoginCredential: !credentialEnabled && account.loginCredential != nil
        )
        saving = true
        Task {
            let updated = await session.updateAccount(account, request: request)
            saving = false
            if updated { dismiss() }
        }
    }
}

private struct TokenRevealView: View {
    @Environment(\.dismiss) private var dismiss
    let account: CreateAccountResponse

    var body: some View {
        NavigationStack {
            Form {
                Section("新令牌") {
                    LabeledContent("账户", value: account.label)
                    if let username = account.loginCredential?.username {
                        LabeledContent("用户名", value: username)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("只显示一次", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(RadioPalette.warning)
                        Text(account.token)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("保存系统令牌")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") { dismiss() }
            }
        }
    }
}

private struct PairingCodeCard: View {
    let pairing: MobilePairingCodeResponse

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 8) {
                Text(pairing.code)
                    .font(.system(size: 38, weight: .bold, design: .monospaced))
                    .tracking(9)
                    .textSelection(.enabled)
                Text(remainingText(at: context.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RadioPalette.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(18)
            .background(RadioPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(RadioPalette.accent.opacity(0.3))
            }
        }
    }

    private func remainingText(at date: Date) -> String {
        let expiration = pairing.expiresAt > 10_000_000_000 ? pairing.expiresAt / 1_000 : pairing.expiresAt
        let remaining = max(0, Int(expiration - date.timeIntervalSince1970))
        return remaining > 0 ? "剩余 \(remaining) 秒" : "已过期"
    }
}

private struct CreateAccountView: View {
    @EnvironmentObject private var session: TX5DRSession
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var username = ""
    @State private var password = ""
    @State private var role: UserRole = .operator
    @State private var selectedOperators = Set<String>()
    @State private var allowSelfService = true
    @State private var created: CreateAccountResponse?
    @State private var creating = false

    var body: some View {
        NavigationStack {
            Form {
                if let created {
                    Section("账户已创建") {
                        LabeledContent("用户名", value: created.loginCredential?.username ?? username)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("应急令牌（仅在这里显示）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(created.token)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    Section("登录信息") {
                        TextField("显示名称", text: $label)
                        TextField("用户名（3–32 位）", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("密码（至少 8 位）", text: $password)
                    }
                    Section("权限") {
                        Picker("角色", selection: $role) {
                            Text("操作员").tag(UserRole.operator)
                            Text("管理员").tag(UserRole.admin)
                        }
                        Toggle("允许自行修改登录密码", isOn: $allowSelfService)
                    }
                    if role == .operator {
                        Section("可用操作员") {
                            ForEach(session.operators) { item in
                                Button {
                                    if selectedOperators.contains(item.id) { selectedOperators.remove(item.id) }
                                    else { selectedOperators.insert(item.id) }
                                } label: {
                                    HStack {
                                        Text(item.myCallsign)
                                            .foregroundStyle(Color.primary)
                                        Spacer()
                                        if selectedOperators.contains(item.id) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(RadioPalette.accent)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(created == nil ? "创建账户" : "保存令牌")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(created == nil ? "取消" : "完成") { dismiss() }
                }
                if created == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(creating ? "创建中" : "创建") { create() }
                            .disabled(!valid || creating)
                    }
                }
            }
        }
    }

    private var valid: Bool {
        !label.isEmpty && username.count >= 3 && password.count >= 8 && (role == .admin || !selectedOperators.isEmpty)
    }

    private func create() {
        creating = true
        Task {
            created = await session.createAccount(
                label: label,
                username: username,
                password: password,
                role: role,
                operatorIds: role == .admin ? [] : Array(selectedOperators),
                allowSelfService: allowSelfService
            )
            creating = false
        }
    }
}
