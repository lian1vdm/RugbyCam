import SwiftUI

/// Pick the iPhone and type the PIN shown in RugbyCam > Settings > iPad remote.
struct ConnectView: View {
    @EnvironmentObject var client: PhoneClient
    @EnvironmentObject var finder: PhoneFinder

    @State private var chosenAddress = ""
    @State private var pin = ""
    @State private var manual = false
    @FocusState private var pinFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RugbyCam Remote")
                        .font(.largeTitle.weight(.bold))
                    Text("Control the iPhone that films the match.")
                        .foregroundColor(Theme.dim)
                }

                if client.link == .wrongPin {
                    Label("The PIN was not accepted. Check it in RugbyCam on the iPhone: Settings > iPad remote.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(Theme.gold)
                }

                card {
                    HStack {
                        Text("iPhones found")
                            .font(.headline)
                        Spacer()
                        ProgressView()
                        Button {
                            finder.restart()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .padding(.leading, 8)
                    }
                    if finder.phones.isEmpty {
                        Text("Looking… On the iPhone open RugbyCam and turn on Settings > iPad remote > Allow control from an iPad. Both devices need the same Wi-Fi, or join the iPhone's Personal Hotspot with the iPad.")
                            .font(.callout)
                            .foregroundColor(Theme.dim)
                    }
                    ForEach(finder.phones) { phone in
                        Button {
                            if let address = phone.address {
                                chosenAddress = address
                                manual = false
                                pinFocused = true
                            }
                        } label: {
                            HStack {
                                Image(systemName: "iphone.gen3")
                                    .font(.title2)
                                VStack(alignment: .leading) {
                                    Text(phone.id)
                                        .foregroundColor(.white)
                                    Text(phone.address ?? "finding the address…")
                                        .font(.caption.monospaced())
                                        .foregroundColor(Theme.dim)
                                }
                                Spacer()
                                if phone.address != nil && phone.address == chosenAddress {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(Theme.green)
                                        .font(.title2)
                                }
                            }
                            .padding(12)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(phone.address == nil)
                    }
                    if let problem = finder.problem {
                        Text(problem)
                            .font(.callout)
                            .foregroundColor(Theme.gold)
                    }
                    Button(manual ? "Hide address field" : "Type the address instead") {
                        manual.toggle()
                    }
                    .font(.callout)
                    if manual {
                        TextField("192.168.1.23:8080", text: $chosenAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .keyboardType(.URL)
                            .font(.title3.monospaced())
                            .padding(12)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Text("The address is shown in RugbyCam on the iPhone under Settings > iPad remote.")
                            .font(.caption)
                            .foregroundColor(Theme.dim)
                    }
                }

                card {
                    Text("PIN")
                        .font(.headline)
                    TextField("4 digits", text: $pin)
                        .keyboardType(.numberPad)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .focused($pinFocused)
                        .padding(12)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .onChange(of: pin) { _, value in
                            let digits = String(value.filter { $0.isNumber }.prefix(4))
                            if digits != value {
                                pin = digits
                            }
                        }
                }

                Button {
                    pinFocused = false
                    client.connect(to: chosenAddress, pin: pin)
                } label: {
                    Text("Connect")
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(canConnect ? Theme.gold : Color.white.opacity(0.12))
                        .foregroundColor(canConnect ? .black : Theme.dim)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!canConnect)
            }
            .padding(24)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            if chosenAddress.isEmpty {
                chosenAddress = client.address
            }
            if pin.isEmpty {
                pin = client.pin
            }
            finder.start()
        }
        .onChange(of: finder.phones) { _, phones in
            // Pick the only phone found, or the one used last time.
            if chosenAddress.isEmpty || !phones.contains(where: { $0.address == chosenAddress }) && !manual {
                let addresses = phones.compactMap { $0.address }
                if addresses.contains(client.address) {
                    chosenAddress = client.address
                } else if addresses.count == 1 {
                    chosenAddress = addresses[0]
                }
            }
        }
    }

    private var canConnect: Bool {
        return !chosenAddress.trimmingCharacters(in: .whitespaces).isEmpty && pin.count == 4
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
