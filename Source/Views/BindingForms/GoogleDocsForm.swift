//
//  GoogleDocsForm.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

struct GoogleDocsForm: View {
    @Binding var binding: GoogleFormState
    let accounts: [GoogleAccount]

    var body: some View {
        AppCard("Google Docs") {
            VStack(spacing: 0) {
                AppSettingRow("Account", description: nil) {
                    Picker("", selection: $binding.email) {
                        Text("Select…").tag("")
                        ForEach(accounts) { account in
                            Text(account.displayName).tag(account.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Drive folder (optional)", description: "Drive folder ID. Leave blank to drop docs at the user's root.") {
                    TextField("Drive folder ID", text: $binding.folderId)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Append mode", description: nil) {
                    Picker("", selection: $binding.appendMode) {
                        ForEach(GoogleDocsDestinationConfig.AppendMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }
            }
        }
    }
}
