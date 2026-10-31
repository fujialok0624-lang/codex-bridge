import Foundation
import MCP
import Testing
@testable import BridgeMCP

@Suite("Modern MCP result envelopes")
struct ModernMCPResultTests {
  private static func makeServer() async -> Server {
    let server = Server(
      name: "result-regression", version: "1",
      capabilities: .init(resources: .init(), tools: .init())
    )
    await server.withMethodHandler(ListTools.self) { _ in
      ListTools.Result(tools: [])
    }
    await server.withMethodHandler(CallTool.self) { _ in
      CallTool.Result(content: [.text("ok")])
    }
    await server.withMethodHandler(ReadResource.self) { parameters in
      ReadResource.Result(contents: [.text("ok", uri: parameters.uri)])
    }
    return server
  }

  private func makeRegistry() -> MCPSessionRegistry {
    MCPSessionRegistry(
      boundPort: 18765,
      serverFactory: { _ in await Self.makeServer() },
      statelessServerFactory: { await Self.makeServer() }
    )
  }

  private func object(_ response: HTTPResponse) async throws -> [String: Any] {
    if let data = response.bodyData {
      return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    if case .stream(let events, _) = response {
      for try await event in events {
        for line in String(decoding: event, as: UTF8.self).components(separatedBy: "\n") {
          guard line.hasPrefix("data:") else { continue }
          let data = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
          return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
      }
    }
    throw MCPError.internalError("Expected a JSON-RPC response")
  }

  @Test(arguments: ["tools/list", "resources/read", "tools/call"])
  func modernRequestsHaveCompleteResults(method: String) async throws {
    let registry = makeRegistry()
    var parameters: [String: Any] = [
      "_meta": [
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": [String: String](),
      ]
    ]
    var headers = [
      "Host": "127.0.0.1:18765",
      "Content-Type": "application/json",
      "Accept": "application/json, text/event-stream",
      "Mcp-Protocol-Version": "2026-07-28",
      "Mcp-Method": method,
    ]
    if method == "resources/read" {
      parameters["uri"] = "bridge://test"
      headers["Mcp-Name"] = "bridge://test"
    } else if method == "tools/call" {
      parameters["name"] = "echo"
      headers["Mcp-Name"] = "echo"
    }
    let request = HTTPRequest(
      method: "POST", headers: headers,
      body: try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": 7, "method": method, "params": parameters,
      ]), path: "/mcp"
    )
    let response = await registry.handle(request)
    #expect(response.statusCode == 200)
    #expect(response.headers[HTTPHeaderName.sessionID] == nil)
    let envelope = try await object(response)
    #expect(envelope["id"] as? Int == 7)
    let result = try #require(envelope["result"] as? [String: Any])
    #expect(result["resultType"] as? String == "complete")
    #expect(result["_meta"] as? [String: Any] != nil)
    let payloadKey = method == "tools/list" ? "tools" : method == "resources/read" ? "contents" : "content"
    #expect(result[payloadKey] as? [Any] != nil)
    await registry.stop()
  }

  @Test
  func existingResultTypeAndMetadataArePreserved() async throws {
    let registry = makeRegistry()
    let original = Data(#"{"jsonrpc":"2.0","id":4,"result":{"resultType":"input_required","inputRequests":{},"_meta":{"custom":"keep"}}}"#.utf8)
    let response = await registry.addingModernServerInfo(
      to: .data(original, headers: ["Content-Type": "application/json"])
    )
    let envelope = try await object(response)
    let result = try #require(envelope["result"] as? [String: Any])
    #expect(result["resultType"] as? String == "input_required")
    #expect(result["inputRequests"] as? [String: Any] != nil)
    let metadata = try #require(result["_meta"] as? [String: Any])
    #expect(metadata["custom"] as? String == "keep")
    #expect(metadata["io.modelcontextprotocol/serverInfo"] as? [String: Any] != nil)
  }

  @Test
  func jsonRPCErrorsAreNotConvertedToCompleteResults() async throws {
    let registry = makeRegistry()
    let data = Data(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"invalid"}}"#.utf8)
    let response = await registry.addingModernServerInfo(to: .data(data))
    #expect(response.bodyData == data)
    let error = HTTPResponse.error(statusCode: 400, .invalidParams("invalid"))
    let normalizedError = await registry.addingModernServerInfo(to: error)
    #expect(normalizedError.statusCode == 400)
    #expect(normalizedError.bodyData == error.bodyData)
  }

  @Test
  func legacyInitializationAndToolListingRemainUnchanged() async throws {
    let registry = makeRegistry()
    let headers = [
      "Host": "127.0.0.1:18765",
      "Content-Type": "application/json",
      "Accept": "application/json, text/event-stream",
    ]
    let initialize = HTTPRequest(
      method: "POST", headers: headers,
      body: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"regression","version":"1"}}}"#.utf8),
      path: "/mcp"
    )
    let initialized = await registry.handle(initialize)
    #expect(initialized.statusCode == 200)
    let sessionID = try #require(initialized.headers[HTTPHeaderName.sessionID])
    let initializationEnvelope = try await object(initialized)
    let initializationResult = try #require(initializationEnvelope["result"] as? [String: Any])
    #expect(initializationResult["protocolVersion"] as? String == "2025-11-25")
    #expect(initializationResult["resultType"] == nil)
    var sessionHeaders = headers
    sessionHeaders[HTTPHeaderName.sessionID] = sessionID
    sessionHeaders["MCP-Protocol-Version"] = "2025-11-25"
    let listed = await registry.handle(HTTPRequest(
      method: "POST", headers: sessionHeaders,
      body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#.utf8),
      path: "/mcp"
    ))
    #expect(listed.statusCode == 200)
    let listingEnvelope = try await object(listed)
    let listingResult = try #require(listingEnvelope["result"] as? [String: Any])
    #expect(listingResult["tools"] as? [Any] != nil)
    #expect(listingResult["resultType"] == nil)
    _ = await registry.handle(HTTPRequest(method: "DELETE", headers: sessionHeaders, path: "/mcp"))
    await registry.stop()
  }
}
