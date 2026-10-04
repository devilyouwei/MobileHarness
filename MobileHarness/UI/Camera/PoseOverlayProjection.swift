extension PoseOverlay.Joint {
    /// Undo upright rotation; native preview conversion subsequently handles crop/mirroring.
    public func sensorPoint(rotation: Int) -> (x: Double, y: Double) {
        let x = Double(x) / 10000
        let y = Double(y) / 10000
        switch rotation {
        case 1: return (y, 1 - x)
        case 2: return (1 - x, 1 - y)
        case 3: return (1 - y, x)
        default: return (x, y)
        }
    }
}
