//
//  RuleSheetView.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import SwiftUI
import AppKit

/// Slide-up panel shown under the notebook list when a notebook is
/// selected. Lets the user attach zero or more destinations to that
/// notebook and tweak shared (rule-level) sync behaviour.
struct RuleSheetView: View {
    let notebook: RmNotebook
    var onClose: () -> Void
    var onSyncNow: (String, String?) -> Void   // (ruleId, optional bindingId)

    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    @State private var addBindingKind: DestinationKind?
    @State private var existingBindingIdToEdit: String?

    /// Either an existing rule for this notebook, or nil. When nil we
    /// create a fresh rule the first time the user attaches a destination.
    private var rule: SyncRule? {
        ledger.rule(forNotebookId: notebook.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ruleSettingsCard
                    destinationsCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            Divider().background(theme.divider)
            footer
        }
        .background(theme.surface)
        .sheet(item: $addBindingKind) { kind in
            BindingEditorSheet(
                kind: kind,
                notebook: notebook,
                existingBinding: nil,
                onSave: { binding in
                    let ruleId = ensureRule().id
                    ledger.addBinding(ruleId: ruleId, binding: binding)
                    addBindingKind = nil
                },
                onCancel: { addBindingKind = nil }
            )
        }
        .sheet(isPresented: Binding(
            get: { existingBindingIdToEdit != nil },
            set: { if !$0 { existingBindingIdToEdit = nil } }
        )) {
            if let id = existingBindingIdToEdit,
               let rule, let binding = rule.destinations.first(where: { $0.id == id }) {
                BindingEditorSheet(
                    kind: binding.kind,
                    notebook: notebook,
                    existingBinding: binding,
                    onSave: { updated in
                        ledger.updateBinding(ruleId: rule.id, binding: updated)
                        existingBindingIdToEdit = nil
                    },
                    onCancel: { existingBindingIdToEdit = nil }
                )
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule == nil ? "Set up sync for this notebook" : "Edit sync rule")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text("\(notebook.name) · \(notebook.pageCount) page\(notebook.pageCount == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
            }
            Spacer()
            if let rule {
                Toggle("", isOn: ruleEnabledBinding(rule))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(theme.primary)
                Text(rule.enabled ? "Enabled" : "Disabled")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(rule.enabled ? theme.success : theme.tertiary)
                AppSecondaryButton(title: "Delete rule", systemImage: "trash", tint: .destructive) {
                    ledger.deleteRule(id: rule.id)
                    onClose()
                }
            }
            AppIconButton(systemName: "xmark", help: "Close") { onClose() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Rule-level settings card

    private var ruleSettingsCard: some View {
        AppCard("Defaults for this notebook") {
            VStack(spacing: 0) {
                AppSettingRow("Title strategy", description: "How each page is titled at every destination.") {
                    Picker("", selection: titleStrategyBinding) {
                        ForEach(TitleStrategy.allCases) { strategy in
                            Text(strategy.label).tag(strategy)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                if currentTitleStrategy == .template {
                    AppRowDivider().padding(.vertical, 10)
                    AppSettingRow("Template", description: "Tokens: {notebook}, {page_n}, {date}") {
                        TextField("Template", text: titleTemplateBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 280)
                    }
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("OCR mode", description: "What to transcribe.") {
                    Picker("", selection: ocrModeBinding) {
                        ForEach(OcrMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                AppRowDivider().padding(.vertical, 10)
                AppSettingRow("Attach PDF", description: "Save the source PDF alongside transcribed text where the destination supports it.") {
                    Toggle("", isOn: savePdfBinding)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(theme.primary)
                }
            }
        }
    }

    // MARK: Destinations card

    private var destinationsCard: some View {
        AppCard("Destinations") {
            VStack(spacing: 10) {
                if let rule, !rule.destinations.isEmpty {
                    ForEach(rule.destinations) { binding in
                        DestinationBindingRow(
                            binding: binding,
                            onEdit: { existingBindingIdToEdit = binding.id },
                            onSyncNow: { onSyncNow(rule.id, binding.id) },
                            onToggle: { newValue in
                                var copy = binding
                                copy.enabled = newValue
                                ledger.updateBinding(ruleId: rule.id, binding: copy)
                            },
                            onRemove: { ledger.removeBinding(ruleId: rule.id, bindingId: binding.id) }
                        )
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "tray")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(theme.tertiary)
                        Text("No destinations yet")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.foregroundSoft)
                        Text("Add one or more places to send transcribed notes from this notebook.")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(DestinationKind.allCases) { kind in
                        addBindingButton(kind: kind)
                    }
                }
            }
        }
    }

    private func addBindingButton(kind: DestinationKind) -> some View {
        Button(action: { addBindingKind = kind }) {
            HStack(spacing: 8) {
                DestinationIcon(kind: kind, size: 18)
                Text("Add \(kind.label)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.foreground)
                Spacer()
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).fill(theme.cardElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).strokeBorder(theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            if let rule, !rule.destinations.isEmpty {
                AppPrimaryButton(title: "Sync all destinations now", systemImage: "arrow.triangle.2.circlepath") {
                    onSyncNow(rule.id, nil)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.background)
    }

    // MARK: Bindings & helpers

    private func ensureRule() -> SyncRule {
        if let rule { return rule }
        let new = SyncRule.new(notebookId: notebook.id, notebookName: notebook.name)
        ledger.upsertRule(new)
        return new
    }

    private var currentRule: SyncRule { rule ?? SyncRule.new(notebookId: notebook.id, notebookName: notebook.name) }

    private var currentTitleStrategy: TitleStrategy { rule?.titleStrategy ?? .firstLineOfOcr }

    private func ruleEnabledBinding(_ rule: SyncRule) -> Binding<Bool> {
        Binding(
            get: { rule.enabled },
            set: { newValue in
                var copy = rule
                copy.enabled = newValue
                ledger.upsertRule(copy)
            }
        )
    }

    private var titleStrategyBinding: Binding<TitleStrategy> {
        Binding(
            get: { rule?.titleStrategy ?? .firstLineOfOcr },
            set: { newValue in
                var copy = ensureRule()
                copy.titleStrategy = newValue
                ledger.upsertRule(copy)
            }
        )
    }

    private var titleTemplateBinding: Binding<String> {
        Binding(
            get: { rule?.titleTemplate ?? "{notebook} – page {page_n}" },
            set: { newValue in
                var copy = ensureRule()
                copy.titleTemplate = newValue
                ledger.upsertRule(copy)
            }
        )
    }

    private var ocrModeBinding: Binding<OcrMode> {
        Binding(
            get: { rule?.ocrMode ?? .all },
            set: { newValue in
                var copy = ensureRule()
                copy.ocrMode = newValue
                ledger.upsertRule(copy)
            }
        )
    }

    private var savePdfBinding: Binding<Bool> {
        Binding(
            get: { rule?.savePdfAttachment ?? true },
            set: { newValue in
                var copy = ensureRule()
                copy.savePdfAttachment = newValue
                ledger.upsertRule(copy)
            }
        )
    }
}

// MARK: - Row showing one configured binding

private struct DestinationBindingRow: View {
    let binding: DestinationBinding
    let onEdit: () -> Void
    let onSyncNow: () -> Void
    let onToggle: (Bool) -> Void
    let onRemove: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DestinationIcon(kind: binding.kind, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(binding.configuration.summary)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(binding.kind.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.tertiary)
                    if let lastRun = binding.lastRunAt {
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.tertiary)
                        Text("Last run \(Formatters.relativeLabel(for: lastRun))")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.muted)
                    }
                    if let error = binding.lastRunError {
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.tertiary)
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.destructive)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)

            Toggle("", isOn: Binding(get: { binding.enabled }, set: onToggle))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(theme.primary)

            AppIconButton(systemName: "arrow.triangle.2.circlepath", help: "Sync this destination now", spinOnTap: true) { onSyncNow() }
            AppIconButton(systemName: "pencil", help: "Edit destination") { onEdit() }
            AppIconButton(systemName: "trash", help: "Remove destination", tint: .destructive) { onRemove() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).fill(theme.cardInset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).strokeBorder(theme.border, lineWidth: 1)
        )
    }
}
