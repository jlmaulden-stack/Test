import SwiftUI
import UIKit

struct GenerateView: View {
    @EnvironmentObject private var store: POStore
    @FocusState private var focusedField: Field?
    @State private var showCopiedToast = false

    enum Field {
        case jobNumber, customerName
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Job") {
                    TextField("Job Number", text: $store.jobNumber)
                        .keyboardType(.numbersAndPunctuation)
                        .focused($focusedField, equals: .jobNumber)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .customerName }

                    TextField("Customer Name", text: $store.customerName)
                        .focused($focusedField, equals: .customerName)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                }

                Section {
                    Button {
                        focusedField = nil
                        Task { await store.generate() }
                    } label: {
                        HStack {
                            Spacer()
                            if store.isGenerating {
                                ProgressView()
                            } else {
                                Text("Generate PO Number")
                                    .bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(!store.canGenerate || store.isGenerating)
                }

                if let po = store.lastGenerated {
                    Section("Generated PO") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(po.poNumber)
                                .font(.system(.largeTitle, design: .monospaced))
                                .bold()
                            Text("\(po.customerName) · Job \(po.jobNumber)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)

                        Button {
                            UIPasteboard.general.string = po.poNumber
                            showCopiedToast = true
                        } label: {
                            Label("Copy PO Number", systemImage: "doc.on.doc")
                        }
                    }
                }

                if let errorMessage = store.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("New PO")
            .overlay(alignment: .bottom) {
                if showCopiedToast {
                    Text("Copied")
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.opacity)
                        .task {
                            try? await Task.sleep(for: .seconds(1.5))
                            showCopiedToast = false
                        }
                }
            }
        }
    }
}

#Preview {
    GenerateView()
        .environmentObject(POStore())
}
