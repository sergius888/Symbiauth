import SwiftUI

@MainActor
struct SettingsScreen: View {
    @ObservedObject var viewModel: PairingViewModel

    var body: some View {
        SettingsView(
            onForgetEndpoint: { viewModel.forgetEndpoint() },
            onCopyRecoveryPhrase: { viewModel.copyRecoveryPhraseDev() },
            onSetDevMode: { viewModel.setDevMode($0) },
            devMode: viewModel.devMode,
            onPingTest: { viewModel.sendPing() },
            onVaultTest: { viewModel.vaultTestEcho() },
            onDevWriteSample: { viewModel.devVaultWrite(key: "sample_test", value: "hello") },
            onDevReadSample: { viewModel.devVaultRead(key: "sample_test") },
            onDevReadFoo: { viewModel.devVaultRead(key: "foo") },
            onDevReadBar: { viewModel.devVaultRead(key: "bar") },
            onDevCredGet: { viewModel.devCredGet(origin: "https://bank.example.com", user: "alice") },
            onDevCredSeed: { viewModel.devSeedCred(origin: "https://bank.example.com", user: "alice", secret: "hunter2") },
            onDevProxIntent: { viewModel.devProxIntent() },
            onDevProxPause: { viewModel.devProxPause(seconds: 300) },
            onDevProxResume: { viewModel.devProxResume() },
            onDevProxStatus: { viewModel.devProxStatus() },
            onGeneratePhrase: { viewModel.generateRecoveryPhrase() },
            onStartRekey: { viewModel.startRekey(countdown: 30) },
            onCommitRekey: { viewModel.commitRekey() },
            onAbortRekey: { viewModel.abortRekey() },
            pendingRekeyToken: viewModel.pendingRekeyToken,
            rekeySecondsLeft: viewModel.rekeySecondsLeft
        )
    }
}
