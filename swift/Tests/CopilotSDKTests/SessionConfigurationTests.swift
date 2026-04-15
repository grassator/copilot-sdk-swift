import Testing
@testable import CopilotSDK

@Test func permissionRequestDecodingKeepsDynamicFields() throws {
    let request = try JSONValue.object([
        "kind": .string("shell"),
        "fullCommandText": .string("git status"),
    ]).decode(PermissionRequest.self)

    #expect(request.kind == "shell")
    #expect(request["fullCommandText"]?.stringValue == "git status")
}

@Test func systemMessageTransformOverridesEncodeAsTransformActions() {
    let configuration = SystemMessageConfiguration(
        mode: .customize,
        sections: [
            "tone": SectionOverride(action: .transform, transform: { current in current + "!" })
        ]
    )

    #expect(configuration.sections["tone"]?.transform != nil)
}
