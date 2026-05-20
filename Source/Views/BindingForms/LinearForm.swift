//
//  LinearForm.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

struct LinearForm: View {
    @Binding var binding: LinearFormState
    let accounts: [LinearAccount]

    var body: some View {
        AppCard("Linear") {
            VStack(spacing: 0) {
                AppSettingRow("Team", description: nil) {
                    Picker("", selection: $binding.workspaceId) {
                        Text("Select…").tag("")
                        ForEach(accounts) { account in
                            Text(account.name).tag(account.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Project (optional)", description: nil) {
                    TextField("Project ID or slug", text: $binding.projectId)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Default label (optional)", description: nil) {
                    TextField("e.g. captured-from-rm", text: $binding.defaultLabel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
            }
        }
    }
}
