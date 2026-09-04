// GatewaySettingsTab.swift
// VocaMac
//
// Settings → Gateway: native-first local VocaGateway controls, phone pairing QR,
// and a Docker fallback CTA when the native binary is missing.

import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

extension Notification.Name {
    /// Menu bar asks Settings to select Gateway and show the pair sheet.
    static let showGatewayPairing = Notification.Name("com.vocamac.showGatewayPairing")
    /// Select a settings sidebar page (`userInfo["page"]` = SettingsPage.rawValue).
    static let selectSettingsPage = Notification.Name("com.vocamac.selectSettingsPage")
}

struct GatewaySettingsTab: View {
    @ObservedObject private var gateway = GatewayProcessManager.shared
    @State private var showingPairSheet = false
    @State private var copiedURL = false

    var body: some View {
        Form {
            Section {
                Text("Optional self-hosted compute for phones and other Voca clients. This is not on-device transcription; audio goes to the Gateway host you run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Status") {
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text(gateway.status.title)
                        .fontWeight(.semibold)
                    Spacer()
                    if gateway.isLive {
                        Text(gateway.isReady ? "Model ready" : "Model may still be downloading")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let path = gateway.binaryPath {
                    LabeledContent("Binary") {
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    Label("Native vocagateway binary not found on PATH", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }

                if let message = gateway.lastErrorMessage, case .error = gateway.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button {
                        Task { await gateway.start() }
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .disabled(gateway.status == .starting || !gateway.isBinaryAvailable || gateway.isLive)

                    Button {
                        Task { await gateway.stop() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .disabled(isStopDisabled)

                    Button {
                        Task { await gateway.refreshStatus() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }

                    Spacer()

                    Button {
                        gateway.openWebUI()
                    } label: {
                        Label("Open WebUI", systemImage: "safari")
                    }
                    .disabled(!gateway.isLive)
                }
            }

            Section("Phone pairing") {
                Text("Show the Pair phone QR once Gateway is live and the pairing URL is a non-loopback address. You can pair while a model is still downloading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField(
                        "Public URL override (LAN / Tailscale)",
                        text: $gateway.publicURLOverride,
                        prompt: Text("http://192.168.x.x:8765")
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await gateway.fetchPairing() }
                    }

                    Button("Apply") {
                        Task { await gateway.fetchPairing() }
                    }
                    .disabled(!gateway.isLive)
                }

                Text("Required when auto-discovery returns localhost. Maps to VOCAGATEWAY_PUBLIC_URL when VocaMac starts Gateway.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if gateway.pairingPayload != nil {
                    HStack {
                        Button {
                            showingPairSheet = true
                        } label: {
                            Label("Show Pair Phone QR", systemImage: "qrcode")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            gateway.copyPairingURLToPasteboard()
                            copiedURL = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copiedURL = false
                            }
                        } label: {
                            Label(copiedURL ? "Copied" : "Copy URL", systemImage: copiedURL ? "checkmark" : "doc.on.doc")
                        }

                        if let url = gateway.pairingPayload?.url {
                            Text(url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                } else if gateway.isLive {
                    Label(
                        "QR hidden until the pairing URL is not localhost / 127.0.0.1.",
                        systemImage: "qrcode.viewfinder"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            if !gateway.isBinaryAvailable {
                Section("Docker fallback") {
                    Text("Native start is the happy path. Docker Desktop is only a fallback when vocagateway is missing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button {
                            gateway.openDockerDesktopInstall()
                        } label: {
                            Label(
                                gateway.isDockerAvailable ? "Docker Desktop docs" : "Install Docker Desktop",
                                systemImage: "shippingbox"
                            )
                        }

                        Button {
                            gateway.openGatewayDocs()
                        } label: {
                            Label("Gateway install docs", systemImage: "book")
                        }

                        Button {
                            gateway.openGatewayRepo()
                        } label: {
                            Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                    }
                }
            }

            Section("Logs") {
                Text("Gateway owns its logs. VocaMac opens Gateway's path under ~/Library/Logs/VocaGateway or ~/.config/vocagateway — it does not store Gateway logs under VocaMac Application Support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    gateway.openGatewayLogs()
                } label: {
                    Label("Open Gateway Logs", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await gateway.refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showGatewayPairing)) { _ in
            if gateway.status.allowsPairing {
                showingPairSheet = true
            }
        }
        .sheet(isPresented: $showingPairSheet) {
            GatewayPairPhoneSheet(
                payloadRaw: gateway.pairingPayloadRaw
                    ?? gateway.pairingPayload.map { encodeCompactPayload($0) },
                urlString: gateway.pairingPayload?.url,
                onCopyURL: {
                    gateway.copyPairingURLToPasteboard()
                },
                onDismiss: { showingPairSheet = false }
            )
        }
    }

    private var isStopDisabled: Bool {
        switch gateway.status {
        case .stopped:
            return true
        case .error:
            return !gateway.isLive
        case .starting, .pairable, .ready:
            return false
        }
    }

    private var statusColor: Color {
        switch gateway.status {
        case .stopped: return .secondary
        case .starting: return .orange
        case .pairable: return .blue
        case .ready: return .green
        case .error: return .red
        }
    }

    private func encodeCompactPayload(_ payload: GatewayPairingPayload) -> String {
        let object: [String: Any] = [
            "v": payload.version,
            "url": payload.url.absoluteString,
            "token": payload.token,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }
}

// MARK: - Pair phone sheet

struct GatewayPairPhoneSheet: View {
    let payloadRaw: String?
    let urlString: String?
    let onCopyURL: () -> Void
    let onDismiss: () -> Void

    @State private var qrImage: NSImage?

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair phone")
                .font(.headline)

            Text("Scan with VocaPhone. The QR encodes the gateway URL and bearer token.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let qrImage {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(8)
                    .background(Color.white)
                    .cornerRadius(8)
            } else {
                ContentUnavailableView(
                    "QR unavailable",
                    systemImage: "qrcode",
                    description: Text("Could not build a QR from the pairing payload.")
                )
                .frame(height: 220)
            }

            if let urlString {
                Text(urlString)
                    .font(.caption)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Copy URL", action: onCopyURL)
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear {
            qrImage = payloadRaw.flatMap { GatewayQRCodeImage.make(from: $0) }
        }
    }
}

// MARK: - QR helper

enum GatewayQRCodeImage {
    static func make(from string: String) -> NSImage? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(trimmed.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scale: CGFloat = 12
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
