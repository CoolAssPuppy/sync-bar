//
//  AppleNotesForm.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI

struct AppleNotesForm: View {
    @Binding var binding: AppleNotesFormState
    let targets: [AppleNotesTarget]

    var body: some View {
        AppCard("Apple Notes") {
            VStack(spacing: 0) {
                AppSettingRow("Folder", description: "SyncNerds creates the folder in iCloud Notes if it doesn't exist.") {
                    TextField("Folder name", text: $binding.folderName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                if !targets.isEmpty {
                    AppRowDivider().padding(.vertical, 10)
                    AppSettingRow("Existing folders", description: nil) {
                        Picker("", selection: $binding.folderName) {
                            ForEach(targets) { target in
                                Text(target.folderName).tag(target.folderName)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 240)
                    }
                }
            }
        }
    }
}
