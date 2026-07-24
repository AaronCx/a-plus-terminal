// a+Terminal VENDOR PATCH (see Package.swift header): PointerPos
// pseudo-encoding (-232, UltraVNC extension) — the server pushes the remote
// cursor's position as a rect whose location is the position, with no
// payload. Together with the Cursor (shape) pseudo-encoding this lets a
// client render the remote cursor without ever injecting input.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol {
	struct PointerPosEncoding: VNCReceivablePseudoEncoding {
		let encodingType = VNCPseudoEncodingType.pointerPos.rawValue
	}
}

extension VNCProtocol.PointerPosEncoding {
	func receive(_ rectangle: VNCProtocol.Rectangle,
				 framebuffer: VNCFramebuffer,
				 connection: NetworkConnectionReading,
				 logger: VNCLogger) async throws {
		// No payload: the rectangle's location IS the cursor position.
		framebuffer.updatePointerPosition(rectangle.region.location)
	}
}
