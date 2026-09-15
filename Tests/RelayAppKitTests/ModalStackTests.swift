import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

@Suite("Modal stack")
@MainActor
struct ModalStackTests {
    @Test("A panel opens, and opening it again puts it away")
    func togglesTopLevelPanels() {
        let model = AppModel()
        model.toggleModal(.ports)
        #expect(model.activeModal == .ports)

        model.toggleModal(.ports)
        #expect(model.activeModal == nil)
    }

    @Test("Top-level panels replace each other rather than piling up")
    func peersReplace() {
        // Opening the ports while the hosts are showing is a change of subject,
        // not a second thing to dismiss.
        let model = AppModel()
        model.toggleModal(.sshHosts)
        model.toggleModal(.ports)

        #expect(model.activeModal == .ports)
        #expect(model.modalStack.count == 1)
    }

    @Test("A panel opened from inside another returns to it")
    func nestedPanelsStack() {
        // The preset editor is reached from Settings; closing it and finding
        // nothing there would lose the user's place.
        let model = AppModel()
        model.toggleModal(.settings)
        model.presentModal(.presetEditor(presetID: nil))
        #expect(model.activeModal == .presetEditor(presetID: nil))

        model.dismissModal()
        #expect(model.activeModal == .settings)
    }

    @Test("Closing the last panel leaves nothing open")
    func dismissingEmptiesTheStack() {
        let model = AppModel()
        model.toggleModal(.settings)
        model.dismissModal()
        #expect(model.activeModal == nil)
        #expect(model.modalStack.isEmpty)
    }

    @Test("Dismissing with nothing open is harmless")
    func dismissingNothingIsSafe() {
        let model = AppModel()
        model.dismissModal()
        #expect(model.modalStack.isEmpty)
    }

    @Test("Presenting the panel already on top does not double it")
    func presentingTheSamePanelTwiceIsIdempotent() {
        let model = AppModel()
        model.toggleModal(.settings)
        model.presentModal(.presetEditor(presetID: "a"))
        model.presentModal(.presetEditor(presetID: "a"))
        #expect(model.modalStack.count == 2)
    }

    @Test("Panels of the same kind for different things are different panels")
    func identityIncludesWhatIsBeingEdited() {
        let first = RelayModal.projectSettings(ProjectID(rawValue: "a"))
        let second = RelayModal.projectSettings(ProjectID(rawValue: "b"))
        #expect(first != second)
        #expect(first.id != second.id)
    }
}
