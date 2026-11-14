import AppKit

extension OperationLog {
    /// "Undo Copy · report.pdf +2", or plain "Undo" when there is nothing to take back.
    var undoMenuTitle: String {
        guard let step = lastUndoable else { return tr("Undo") }
        return tr("Undo %@", step.label)
    }
}

extension ListerViewController {
    /// ⌘Z: takes back the last copy, move, duplicate or Move to Trash done in this session.
    func undoLastOperation() {
        guard OperationLog.shared.lastUndoable != nil else {
            flash(tr("Nothing to undo"))
            return
        }
        flash(tr("Undoing…"))
        OperationLog.shared.undoLast { [weak self] outcome in
            guard let outcome else { return }
            ListerManager.shared.reloadListers(showing: outcome.folders)
            guard let self else { return }
            if outcome.failures.isEmpty {
                self.flash(tr("Undone: %@", outcome.label))
            } else {
                self.model.statusMessage = nil
                self.model.errorMessage = outcome.failures.joined(separator: "; ")
            }
        }
    }
}
