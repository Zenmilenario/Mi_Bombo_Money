import Foundation

/// Compiled with `-D DOBLON_PUBLIC`: the edition for other people keeps the bank connection and leaves
/// out the banking lab.
@main
struct PublicEditionCheck {
    static func main() {
        precondition(!AppEdition.isPersonal, "This check must be compiled as the public edition")
        precondition(!BankingConnectionPolicy.personalServerHost.isEmpty, "The public edition keeps its bank server")
        precondition(BankingConnectionPolicy.entryDestination(cloud: true, testWorkspace: false, testOnly: false) == .personal,
                     "Banks can be connected in the public edition")
        precondition(BankingConnectionPolicy.entryDestination(cloud: true, testWorkspace: false, testOnly: true) == .personal,
                     "No banking lab: the real connection is shown instead")
        precondition(BankingConnectionPolicy.entryDestination(cloud: false, testWorkspace: false, testOnly: false) == .requiresPersonalWorkspace)
        print("Public edition checks passed.")
    }
}
