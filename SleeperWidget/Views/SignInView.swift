import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var username = SharedStore.username ?? ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "football.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            VStack(spacing: 8) {
                Text("Sleeper Widget")
                    .font(.largeTitle.bold())
                Text("Your fantasy matchup on the Lock Screen and in the Dynamic Island while games are on.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Sleeper username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .submitLabel(.go)
                    .focused($focused)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .onSubmit { Task { await model.signIn(username: username) } }
                Text("No password needed. Sleeper's public API only reads league data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            if let error = model.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button {
                Task { await model.signIn(username: username) }
            } label: {
                Group {
                    if model.isBusy {
                        ProgressView().tint(.white)
                    } else {
                        Text("Continue")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy || username.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.horizontal)
            Spacer()
            Spacer()
        }
        .onAppear { focused = username.isEmpty }
    }
}
