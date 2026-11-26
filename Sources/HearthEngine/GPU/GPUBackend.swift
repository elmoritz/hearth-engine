/// The one GPU boundary (invariant 4, Decisions D4). Everything above it is plain Swift values; everything
/// below it is one graphics API. A Metal 4 back end would be a second conformer.
protocol GPUBackend: AnyObject {
    var deviceName: String { get }
    /// What the device offers after restrictions; it decides the pass layout and the texture limit.
    var capabilities: GPUCapabilities { get }
    /// What the last frame did, and how many pipelines were ever built.
    var counters: GPUCounters { get }
    func hasTexture(_ id: TextureID) -> Bool
    func setTexture(_ id: TextureID, image: PixelImage) throws(EngineError)
    /// Draws a validated plan into a fresh private target and reads it back as RGBA8, top row first.
    func render(_ plan: FramePlan, target: RenderTarget) throws(EngineError) -> PixelImage
}

/// Counts for audits and the PERF probes (test rule 10).
public struct GPUCounters: Sendable, Hashable {
    /// Render passes in the last frame (E-PASS-2: 1 on the reference path, 2 on the fallback).
    public var renderPasses = 0
    /// Draw calls in the last frame, the final stage included.
    public var draws = 0
    /// Pipeline binds in the last frame.
    public var pipelineBinds = 0
    /// Pipelines built since the renderer was made: the warm-up's, and nothing after (E-PSO-1).
    public var pipelinesCreated = 0
    /// Pipelines built on the main thread (E-PSO-3: 0).
    public var pipelinesCreatedOnMainThread = 0

    public init() {}
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
