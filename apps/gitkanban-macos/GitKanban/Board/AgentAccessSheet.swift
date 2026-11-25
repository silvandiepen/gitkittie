import GitKanbanKit
import SwiftUI

/// Let agents on this Mac work with the boards through the app, so they need no copy of
/// the repository: turn it on, copy the command, run it once in the agent.
struct AgentAccessSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isOn = false
    @State private var isWorking = false
    @State private var token = ""
    @State private var copied: String?

    /// Through the bridge: no token in the command, and it opens Tasks when it is closed.
    private var claudeCommand: String {
        "claude mcp add --scope user tasks -- /bin/bash \"\(model.agentBridgeScript.path)\""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent Access").font(.headline)
                Text("Agents on this Mac can read and change your boards through the app. They don't need the repository on disk; the app fetches what they ask for and writes their changes straight to it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Let agents connect", isOn: Binding(
                get: { isOn },
                set: { newValue in
                    isOn = newValue
                    isWorking = true
                    Task {
                        await model.setAgentAccess(newValue)
                        token = newValue ? model.agentToken() : ""
                        isWorking = false
                    }
                }
            ))
            .disabled(isWorking)

            if isOn {
                if let error = model.agentServerError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red)
                } else if model.agentServerPort != nil {
                    Label("Listening on this Mac only, at \(model.agentServerURL)", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.green)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Connect Claude Code").font(.subheadline.weight(.medium))
                    Text("Run this once in a terminal. Agents then open Tasks by themselves when it is closed.")
                        .font(.caption).foregroundStyle(.secondary)
                    copyRow(claudeCommand, label: "Copy Command", key: "command")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Other agents").font(.subheadline.weight(.medium))
                    Text("Use the same command as a stdio MCP server, or add an HTTP server with this address and header (Tasks must already be open for that).")
                        .font(.caption).foregroundStyle(.secondary)
                    copyRow(model.agentServerURL, label: "Copy Address", key: "url")
                    copyRow("Authorization: Bearer \(token)", label: "Copy Header", key: "header")
                }

                HStack {
                    Button("New Token") {
                        isWorking = true
                        Task {
                            await model.resetAgentToken()
                            token = model.agentToken()
                            isWorking = false
                        }
                    }
                    .disabled(isWorking)
                    Text("Locks out agents set up with the address and header. Agents using the command are not affected.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Tell your agents about Tasks").font(.subheadline.weight(.medium))
                    Text("Paste this into your agent's instructions (CLAUDE.md or AGENTS.md) so every session knows what Tasks is, how to reach it and how to work with your boards.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        Text(model.agentPrompt)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 160)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("agentPrompt")
                    HStack {
                        Spacer()
                        Button(copied == "prompt" ? "Copied" : "Copy Prompt") {
                            Platform.copy(model.agentPrompt)
                            copied = "prompt"
                        }
                        .controlSize(.small)
                    }
                }

                Text("Agents see the boards in your sidebar and can create, change, move and claim cards on them.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            isOn = model.agentAccessEnabled
            token = isOn ? model.agentToken() : ""
        }
    }

    /// A line of text to copy, shown shortened; the token is never laid out in full.
    private func copyRow(_ text: String, label: String, key: String) -> some View {
        HStack(spacing: 8) {
            Text(text.replacingOccurrences(of: token, with: token.isEmpty ? "" : String(token.prefix(6)) + "…"))
                .font(.caption.monospaced())
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            Button(copied == key ? "Copied" : label) {
                Platform.copy(text)
                copied = key
            }
            .controlSize(.small)
        }
    }
}
