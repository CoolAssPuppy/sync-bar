//
//  OnboardingView.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  First-run flow: pair the reMarkable, connect an app, then make a sync.
//

import SwiftUI

struct OnboardingView: View {
    var onFinish: () -> Void

    @ObservedObject private var ledger = Ledger.shared
    @Environment(\.theme) private var theme

    private enum Step: Int, CaseIterable { case pair, connect, done }
    @State private var step: Step = .pair
    @State private var isAddingApp = false

    private var isPaired: Bool { ledger.remarkableAccount != nil }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            VStack(spacing: 28) {
                brand
                stepDots
                card
            }
            .frame(maxWidth: 560)
            .padding(40)
        }
        .sheet(isPresented: $isAddingApp) { AddDestinationSheet(isPresented: $isAddingApp) }
    }

    private var brand: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(theme.primary)
            Text("Welcome to Sync Bar")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(theme.foreground)
            Text("Turn your reMarkable notes into clean text in the apps you already use.")
                .font(.system(size: 14))
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s == step ? theme.primary : theme.border)
                    .frame(width: s == step ? 22 : 7, height: 7)
            }
        }
    }

    @ViewBuilder
    private var card: some View {
        switch step {
        case .pair:    pairStep
        case .connect: connectStep
        case .done:    doneStep
        }
    }

    private var pairStep: some View {
        VStack(spacing: 18) {
            RemarkablePairPanel(
                title: "Step 1 — Pair your reMarkable",
                onClose: nil,
                onPaired: { withAnimation { step = .connect } }
            )
            .background(Color.clear)
            if isPaired {
                PillButton(title: "Continue", systemImage: "arrow.right") { withAnimation { step = .connect } }
            }
        }
        .padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
    }

    private var connectStep: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.2x2").font(.system(size: 30, weight: .light)).foregroundStyle(theme.primary)
                Text("Step 2 — Connect an app").font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.foreground)
                Text("Pick where your notes should go. You can add more later.")
                    .font(.system(size: 13)).foregroundStyle(theme.muted).multilineTextAlignment(.center)
            }
            if ledger.hasAnyDestination {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
                    Text("\(ledger.connectedAppCount) app\(ledger.connectedAppCount == 1 ? "" : "s") connected")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.foregroundSoft)
                }
            }
            HStack(spacing: 10) {
                PillButton(title: "Connect an app", systemImage: "plus") { isAddingApp = true }
                if ledger.hasAnyDestination {
                    PillButton(title: "Continue", systemImage: "arrow.right", filled: false) { withAnimation { step = .done } }
                } else {
                    PillButton(title: "Skip for now", filled: false) { withAnimation { step = .done } }
                }
            }
        }
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
    }

    private var doneStep: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundStyle(theme.primary)
            VStack(spacing: 6) {
                Text("You're set").font(.system(size: 20, weight: .bold)).foregroundStyle(theme.foreground)
                Text("Make your first sync: from a folder, to an app, synced how.")
                    .font(.system(size: 13.5)).foregroundStyle(theme.muted).multilineTextAlignment(.center)
            }
            PillButton(title: "Open Sync Bar", systemImage: "arrow.right") { onFinish() }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
    }
}
