import Cocoa
import OptiStatsCore

/// Gerenciador de memória: análise → OptimizationAdvisor → seleção do usuário → confirmação →
/// OptimizationCoordinator (pedido de encerramento NORMAL, nunca forçado) → relatório sem falsa atribuição.
///
/// Nada é encerrado sem ação explícita: nenhum app vem pré-selecionado e a confirmação lista o que será pedido.
final class MemoryOptimizerPanel: NSStackView {
    private let env: AppEnvironment
    var onLayoutChange: (() -> Void)?

    private let intro = Fmt.note(L("opt.intro"), lines: 5)
    private let analyzeButton = NSButton(title: L("opt.analyze"), target: nil, action: nil)
    private let detail = NSStackView.vertical(spacing: 6)
    private let closeButton = NSButton(title: L("opt.closeSelected"), target: nil, action: nil)
    private let cancelButton = NSButton(title: L("opt.cancel"), target: nil, action: nil)

    private var checks: [(button: NSButton, candidate: ReclaimCandidate)] = []
    private var cancelToken: CancelToken?
    private var running = false

    init(env: AppEnvironment) {
        self.env = env
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false

        for b in [analyzeButton, closeButton, cancelButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.target = self
            b.translatesAutoresizingMaskIntoConstraints = false
        }
        analyzeButton.action = #selector(analyzeTapped)
        closeButton.action = #selector(closeSelectedTapped)
        cancelButton.action = #selector(cancelTapped)
        closeButton.isEnabled = false
        closeButton.isHidden = true
        cancelButton.isHidden = true

        addFullWidth(intro)
        let buttons = NSStackView.horizontal([analyzeButton, closeButton, cancelButton], spacing: 8)
        addArrangedSubview(buttons)
        addFullWidth(detail)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    // MARK: Ações

    @objc private func analyzeTapped() {
        guard !running else { return }
        let advice = env.currentAdvice()
        showAdvice(advice)
    }

    @objc private func cancelTapped() {
        cancelToken?.cancel()
        cancelButton.isEnabled = false
    }

    @objc private func checkChanged() {
        closeButton.isEnabled = !running && checks.contains { $0.button.state == .on }
    }

    @objc private func closeSelectedTapped() {
        guard !running else { return }
        let selected = checks.filter { $0.button.state == .on }.map(\.candidate)
        guard !selected.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("opt.confirm.title", selected.count)
        let names = selected.map { "• \($0.group.displayName)" }.joined(separator: "\n")
        alert.informativeText = names + "\n\n" + L("opt.confirm.body")
        alert.addButton(withTitle: L("opt.confirm.ok"))
        alert.addButton(withTitle: L("opt.confirm.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(selected)
    }

    private func run(_ selected: [ReclaimCandidate]) {
        running = true
        analyzeButton.isEnabled = false
        closeButton.isEnabled = false
        cancelButton.isHidden = false
        cancelButton.isEnabled = true
        clearDetail()
        detail.addFullWidth(Fmt.note(L("opt.running"), lines: 3, size: 11))
        onLayoutChange?()

        let items = selected.map { OptimizationItem(group: $0.group) }
        let token = CancelToken()
        cancelToken = token
        let coordinator = env.makeOptimizer()
        Task { @MainActor [weak self] in
            let report = await coordinator.run(items: items, cancel: token)
            self?.finish(report)
        }
    }

    private func finish(_ report: ReclaimReport) {
        running = false
        cancelToken = nil
        analyzeButton.isEnabled = true
        analyzeButton.title = L("opt.analyzeAgain")
        cancelButton.isHidden = true
        closeButton.isHidden = true
        checks = []
        showReport(report)
    }

    // MARK: Apresentação

    private func clearDetail() {
        for v in detail.arrangedSubviews {
            detail.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
    }

    private func showAdvice(_ advice: Advice) {
        clearDetail()
        checks = []
        closeButton.isHidden = true
        closeButton.isEnabled = false

        let headline = Fmt.note("", lines: 5, size: 12)
        var reasons: [AssessmentReason] = []
        switch advice.assessment {
        case .insufficientData:
            headline.setText(L("opt.insufficient"))
        case .healthy:
            headline.setText(L("opt.healthy"))
            headline.textColor = Theme.good
        case .watch(let r):
            headline.setText(L("opt.watch")); reasons = r
        case .actionRecommended(let r):
            headline.setText(L("opt.action")); reasons = r
            headline.textColor = Theme.warn
        }
        detail.addFullWidth(headline)
        for r in reasons { detail.addFullWidth(Fmt.note("• " + reasonText(r), lines: 3, size: 10.5)) }

        if !advice.candidates.isEmpty {
            detail.addFullWidth(SectionHeaderView(L("opt.candidates")))
            detail.addFullWidth(Fmt.note(L("opt.candidatesNote"), lines: 4, size: 10))
            for c in advice.candidates {
                let title = L("opt.candidateTitle", c.group.displayName, Fmt.bytes(c.estimatedReclaimBytes))
                let box = NSButton(checkboxWithTitle: title, target: self, action: #selector(checkChanged))
                box.state = .off
                box.font = Theme.body(12)
                box.translatesAutoresizingMaskIntoConstraints = false
                checks.append((box, c))
                detail.addFullWidth(box)
                var lines = c.risks.map { riskText($0) }
                if let g = c.growth {
                    lines.append(L("opt.growth", Fmt.bytes(UInt64(max(0, g.bytesPerMinute))), growthConfidenceText(g.confidence)))
                }
                detail.addFullWidth(Fmt.note(lines.joined(separator: " · "), lines: 4, size: 10))
            }
            closeButton.isHidden = false
            checkChanged()
        }

        if !advice.protectedTop.isEmpty {
            detail.addFullWidth(SectionHeaderView(L("opt.protected")))
            for p in advice.protectedTop {
                let why = p.verdict.reasons.map { protectionText($0) }.joined(separator: ", ")
                detail.addFullWidth(Fmt.note("• " + L("opt.protectedRow", p.group.displayName, Fmt.bytes(p.group.footprintBytes), why),
                                             lines: 3, size: 10))
            }
        }
        onLayoutChange?()
    }

    private func showReport(_ report: ReclaimReport) {
        clearDetail()
        detail.addFullWidth(SectionHeaderView(L("opt.report")))
        switch report.summary {
        case .noActionTaken:
            detail.addFullWidth(Fmt.note(L("opt.report.none"), lines: 4, size: 12))
        case .closedApps(let count, let delta):
            detail.addFullWidth(Fmt.note(L("opt.report.closed", count), lines: 3, size: 12))
            if let d = delta {
                detail.addFullWidth(Fmt.note(L("opt.report.availableDelta", Fmt.signedBytes(d)), lines: 3, size: 11))
            }
        case .requestedButStillOpen(let count):
            detail.addFullWidth(Fmt.note(L("opt.report.stillOpen", count), lines: 4, size: 12))
        }
        if let s = report.swapUsedDelta {
            detail.addFullWidth(Fmt.note(L("opt.report.swapDelta", Fmt.signedBytes(s)), lines: 3, size: 11))
        }
        for r in report.results {
            detail.addFullWidth(Fmt.note("• " + L("opt.report.item", r.item.group.displayName, outcomeText(r.outcome)), lines: 3, size: 10.5))
        }
        // Sem falsa atribuição: a variação é do sistema inteiro, medida antes/depois.
        detail.addFullWidth(Fmt.note(L("opt.report.disclaimer"), lines: 5, size: 10))
        onLayoutChange?()
    }

    // MARK: Textos

    private func reasonText(_ r: AssessmentReason) -> String {
        switch r {
        case .pressure(let band):
            return band == .high ? L("opt.reason.pressureHigh") : L("opt.reason.pressureAttention")
        case .swapInUse(let bytes): return L("opt.reason.swap", Fmt.bytes(bytes))
        case .activeSwapping(let rate): return L("opt.reason.activeSwap", Fmt.number(rate, decimals: 0, unit: ""))
        case .sustainedGrowth(let name): return L("opt.reason.growth", name)
        }
    }

    private func riskText(_ r: RiskNote) -> String {
        switch r {
        case .mayLoseUnsavedWork: return L("opt.risk.unsaved")
        case .mayInterruptMedia: return L("opt.risk.media")
        case .mayInterruptDownloads: return L("opt.risk.downloads")
        case .manyHelpersShared: return L("opt.risk.helpers")
        case .growthSuspected: return L("opt.risk.growth")
        }
    }

    private func growthConfidenceText(_ c: GrowthSuspicion.Confidence) -> String {
        switch c {
        case .low: return L("opt.confidence.low")
        case .medium: return L("opt.confidence.medium")
        }
    }

    private func protectionText(_ r: ProtectionReason) -> String {
        switch r {
        case .systemOrAppleComponent: return L("opt.prot.system")
        case .rootOwned: return L("opt.prot.root")
        case .thisApp: return L("opt.prot.thisApp")
        case .frontmost: return L("opt.prot.frontmost")
        case .category(let c): return categoryText(c)
        case .userProtected: return L("opt.prot.user")
        case .noIdentity: return L("opt.prot.noIdentity")
        case .essentialProcess: return L("opt.prot.essential")
        }
    }

    private func categoryText(_ c: ProtectedCategory) -> String {
        switch c {
        case .browser: return L("opt.cat.browser")
        case .editorOrIDE: return L("opt.cat.editor")
        case .music: return L("opt.cat.music")
        case .streaming: return L("opt.cat.streaming")
        case .meeting: return L("opt.cat.meeting")
        case .downloads: return L("opt.cat.downloads")
        case .terminal: return L("opt.cat.terminal")
        case .passwordManager: return L("opt.cat.passwords")
        case .backup: return L("opt.cat.backup")
        }
    }

    private func outcomeText(_ o: QuitOutcome) -> String {
        switch o {
        case .quit: return L("opt.out.quit")
        case .stillRunning: return L("opt.out.stillRunning")
        case .requestFailed: return L("opt.out.failed")
        case .skipped(let reason):
            switch reason {
            case .cancelled: return L("opt.skip.cancelled")
            case .identityChanged: return L("opt.skip.identity")
            case .noLeaderProcess: return L("opt.skip.noLeader")
            case .protectedNow: return L("opt.skip.protected")
            }
        }
    }
}
