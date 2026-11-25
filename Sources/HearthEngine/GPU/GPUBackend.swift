/// The one GPU boundary (invariant 4, Decisions D4). Everything above it is plain Swift values; everything
/// below it is one graphics API. A Metal 4 back end, or the Simulator's two-pass path (D18), is a second conformer.
protocol GPUBackend: AnyObject {
    var deviceName: String { get }
    func hasTexture(_ id: TextureID) -> Bool
    func setTexture(_ id: TextureID, image: PixelImage) throws(EngineError)
    /// Draws a validated plan into a fresh private target and reads it back as RGBA8, top row first.
    func render(_ plan: FramePlan, target: RenderTarget) throws(EngineError) -> PixelImage
}

/// Unwraps what a GPU call returned, or throws `gpuFailure` naming what was asked for.
/// Every allocation of a back end goes through here, so a refusal is always a typed error.
func requireGPU<T>(_ what: String, _ make: () throws -> T?) throws(EngineError) -> T {
    let made: T?
    do {
        made = try make()
    } catch {
        throw .gpuFailure("\(what): \(error)")
    }
    guard let made else {
        throw .gpuFailure("\(what): the device returned nothing")
    }
    return made
}
