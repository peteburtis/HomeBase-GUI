//
//  HomeBaseColorPresentation.swift
//  HomeBase-GUI
//

import CoreGraphics
import Foundation
import HomeBaseProtocol
import SwiftUI

/// A display-ready projection of HomeBase's canonical structured Color value.
///
/// HomeBase Color carries chromaticity independently of a light's brightness.
/// The conversion therefore normalizes to the brightest representable color,
/// while preserving an explicit path through CIE XYZ and linear Display P3.
struct HomeBaseColorPresentation: Equatable {
    private let xyz: HomeBaseColorMath.XYZ
    fileprivate let whiteKelvin: Double?

    init?(wireValue: HBJSONValue) {
        guard let parsed = HomeBaseColorMath.parse(wireValue) else {
            return nil
        }
        xyz = parsed.xyz
        whiteKelvin = parsed.whiteKelvin
    }

    fileprivate init?(whiteKelvin: Double) {
        guard let xyz = HomeBaseColorMath.whiteXYZ(kelvin: whiteKelvin) else {
            return nil
        }
        self.xyz = xyz
        self.whiteKelvin = min(25_000, max(1_667, whiteKelvin))
    }

    fileprivate var perceptualPoint: HomeBaseColorMath.Point? {
        HomeBaseColorMath.normalizedOKLabPoint(from: xyz)
    }

    var cgColor: CGColor? {
        if let colorSpace = CGColorSpace(
            name: CGColorSpace.extendedLinearDisplayP3
        ),
        let rgb = HomeBaseColorMath.displayP3(from: xyz),
        let mapped = HomeBaseColorMath.brightestInGamut(rgb) {
            return CGColor(
                colorSpace: colorSpace,
                components: [
                    CGFloat(mapped.red),
                    CGFloat(mapped.green),
                    CGFloat(mapped.blue),
                    1,
                ]
            )
        }

        // All currently supported targets provide Display P3. Keeping an
        // explicit linear-sRGB fallback also makes the conversion safe on a
        // future Apple target whose compositor lacks that named space.
        guard let colorSpace = CGColorSpace(
            name: CGColorSpace.extendedLinearSRGB
        ),
        let rgb = HomeBaseColorMath.linearSRGB(from: xyz),
        let mapped = HomeBaseColorMath.brightestInGamut(rgb) else {
            return nil
        }
        return CGColor(
            colorSpace: colorSpace,
            components: [
                CGFloat(mapped.red),
                CGFloat(mapped.green),
                CGFloat(mapped.blue),
                1,
            ]
        )
    }
}

enum HomeBaseColorAggregatePresentation: Equatable {
    case white(HomeBaseWhiteColorViewport)
    case chromatic(HomeBaseChromaticColorViewport)

    init?(
        wireValues: [HBJSONValue],
        aggregateValueCount: Int?
    ) {
        let colors = wireValues.compactMap { value in
            HomeBaseColorPresentation(wireValue: value)
        }
        guard !colors.isEmpty else { return nil }
        let totalCount = max(aggregateValueCount ?? colors.count, colors.count)

        if colors.allSatisfy({ $0.whiteKelvin != nil }),
           let viewport = HomeBaseWhiteColorViewport(
            colors: colors,
            totalCount: totalCount
           ) {
            self = .white(viewport)
            return
        }

        guard let viewport = HomeBaseChromaticColorViewport(
            colors: colors,
            totalCount: totalCount
        ) else {
            return nil
        }
        self = .chromatic(viewport)
    }

    var totalCount: Int {
        switch self {
        case .white(let viewport):
            viewport.totalCount
        case .chromatic(let viewport):
            viewport.totalCount
        }
    }
}

struct HomeBaseWhiteColorViewport: Equatable {
    let stops: [HomeBaseColorPresentation]
    let totalCount: Int

    fileprivate init?(
        colors: [HomeBaseColorPresentation],
        totalCount: Int
    ) {
        let mireks = colors.compactMap { color -> Double? in
            guard let kelvin = color.whiteKelvin, kelvin > 0 else {
                return nil
            }
            return 1_000_000 / kelvin
        }
        guard !mireks.isEmpty else { return nil }

        // Inverse local density gives an entire clump approximately one vote:
        // eight identical temperatures and one distinct temperature pull the
        // viewport roughly equally instead of eight-to-one.
        let weights = densityCorrectedWeights(
            count: mireks.count,
            bandwidth: 14
        ) { first, second in
            abs(mireks[first] - mireks[second])
        }
        guard let center = weightedMean(mireks, weights: weights) else {
            return nil
        }
        let spread = weightedRootMeanSquareDistance(
            mireks,
            center: center,
            weights: weights
        )

        // A mixed control must visibly read as a range, even when all its
        // constituents are close. The upper bound keeps it a viewport onto
        // the Planckian locus rather than the entire white spectrum.
        let halfSpan = min(85, max(28, 14 + (1.4 * spread)))
        let coldMirek = max(40, center - halfSpan)
        let warmMirek = min(600, center + halfSpan)
        guard coldMirek < warmMirek else { return nil }

        let stopCount = 9
        let colors = (0 ..< stopCount).compactMap { index in
            let progress = Double(index) / Double(stopCount - 1)
            let mirek = coldMirek + ((warmMirek - coldMirek) * progress)
            return HomeBaseColorPresentation(
                whiteKelvin: 1_000_000 / mirek
            )
        }
        guard colors.count == stopCount else { return nil }
        stops = colors
        self.totalCount = totalCount
    }
}

struct HomeBaseChromaticColorViewport: Equatable {
    fileprivate let center: HomeBaseColorMath.Point
    fileprivate let halfSpan: Double
    let totalCount: Int

    fileprivate init?(
        colors: [HomeBaseColorPresentation],
        totalCount: Int
    ) {
        let points = colors.compactMap(\.perceptualPoint)
        guard !points.isEmpty else { return nil }

        let weights = densityCorrectedWeights(
            count: points.count,
            bandwidth: 0.025
        ) { first, second in
            points[first].distance(to: points[second])
        }
        guard let centerX = weightedMean(
            points.map(\.x),
            weights: weights
        ),
        let centerY = weightedMean(
            points.map(\.y),
            weights: weights
        ) else {
            return nil
        }
        let center = HomeBaseColorMath.Point(x: centerX, y: centerY)
        let distances = points.map { $0.distance(to: center) }
        let spread = weightedRootMeanSquareDistance(
            distances,
            center: 0,
            weights: weights
        )

        self.center = center
        // The floor guarantees a visibly multicolored crop at 30 points. The
        // ceiling prevents a broad aggregate from degenerating into the whole
        // generic color wheel.
        halfSpan = min(0.16, max(0.055, 0.03 + (1.35 * spread)))
        self.totalCount = totalCount
    }

    fileprivate var cgImage: CGImage? {
        HomeBaseColorMath.makeChromaticViewportImage(
            center: center,
            halfSpan: halfSpan,
            size: 90
        )
    }
}

enum HomeBaseColorReadoutPresentation: Equatable {
    case selected(HomeBaseColorPresentation)
    case aggregate(HomeBaseColorAggregatePresentation)
    case mixed
    case unavailable
}

struct HomeBaseColorReadout: View {
    let presentation: HomeBaseColorReadoutPresentation
    let accessibilityValue: String
    let isStale: Bool

    var body: some View {
        ZStack {
            switch presentation {
            case .selected(let color):
                Circle()
                    .fill(fillColor(for: color))

            case .aggregate(.white(let viewport)):
                Circle()
                    .fill(
                        LinearGradient(
                            stops: viewport.stops.enumerated().map {
                                index, color in
                                .init(
                                    color: fillColor(for: color),
                                    location: Double(index)
                                        / Double(viewport.stops.count - 1)
                                )
                            },
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

            case .aggregate(.chromatic(let viewport)):
                if let image = viewport.cgImage {
                    Image(decorative: image, scale: 3, orientation: .up)
                        .resizable()
                        .interpolation(.high)
                } else {
                    mixedFallback
                }

            case .mixed:
                mixedFallback

            case .unavailable:
                unavailableFallback
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(
                    isStale
                        ? Color.orange.opacity(0.68)
                        : Color.primary.opacity(0.22),
                    lineWidth: isStale ? 2 : 1
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Color")
        .accessibilityValue(spokenAccessibilityValue)
    }

    private func fillColor(for color: HomeBaseColorPresentation) -> Color {
        color.cgColor.map(Color.init(cgColor:)) ?? .secondary
    }

    private var mixedFallback: some View {
        Circle()
            .fill(
                AngularGradient(
                    colors: [
                        .red,
                        .yellow,
                        .green,
                        .cyan,
                        .blue,
                        .purple,
                        .red,
                    ],
                    center: .center
                )
            )
    }

    private var unavailableFallback: some View {
        ZStack {
            Circle()
                .fill(.secondary.opacity(0.12))
            Image(systemName: "questionmark")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var spokenAccessibilityValue: String {
        let value = switch presentation {
        case .selected:
            accessibilityValue
        case .aggregate(.white(let viewport)):
            "Mixed white temperatures from \(viewport.totalCount) constituent values"
        case .aggregate(.chromatic(let viewport)):
            "Mixed colors from \(viewport.totalCount) constituent values"
        case .mixed:
            "Mixed colors"
        case .unavailable:
            "Color unavailable"
        }
        return isStale ? "\(value), stale" : value
    }
}

private func densityCorrectedWeights(
    count: Int,
    bandwidth: Double,
    distance: (Int, Int) -> Double
) -> [Double] {
    guard count > 0, bandwidth > 0 else { return [] }
    return (0 ..< count).map { first in
        let density = (0 ..< count).reduce(0.0) { partial, second in
            let normalizedDistance = distance(first, second) / bandwidth
            return partial + exp(
                -0.5 * normalizedDistance * normalizedDistance
            )
        }
        return density > 0 ? 1 / density : 0
    }
}

private func weightedMean(
    _ values: [Double],
    weights: [Double]
) -> Double? {
    guard values.count == weights.count, !values.isEmpty else { return nil }
    let totalWeight = weights.reduce(0, +)
    guard totalWeight.isFinite, totalWeight > 0 else { return nil }
    let total = zip(values, weights).reduce(0.0) { partial, item in
        partial + (item.0 * item.1)
    }
    let result = total / totalWeight
    return result.isFinite ? result : nil
}

private func weightedRootMeanSquareDistance(
    _ values: [Double],
    center: Double,
    weights: [Double]
) -> Double {
    guard values.count == weights.count, !values.isEmpty else { return 0 }
    let totalWeight = weights.reduce(0, +)
    guard totalWeight.isFinite, totalWeight > 0 else { return 0 }
    let variance = zip(values, weights).reduce(0.0) { partial, item in
        let distance = item.0 - center
        return partial + (distance * distance * item.1)
    } / totalWeight
    return variance > 0 && variance.isFinite ? sqrt(variance) : 0
}

private enum HomeBaseColorMath {
    struct XYZ: Equatable {
        let x: Double
        let y: Double
        let z: Double
    }

    struct RGB {
        let red: Double
        let green: Double
        let blue: Double

        var components: [Double] {
            [red, green, blue]
        }
    }

    struct Point: Equatable {
        let x: Double
        let y: Double

        func distance(to other: Point) -> Double {
            hypot(x - other.x, y - other.y)
        }
    }

    struct ParsedColor {
        let xyz: XYZ
        let whiteKelvin: Double?
    }

    static func parse(_ wireValue: HBJSONValue) -> ParsedColor? {
        guard let object = wireValue.objectValue,
              object.count == 1,
              let entry = object.first else {
            return nil
        }

        switch entry.key {
        case "RGB":
            guard let values = numericArray(entry.value, count: 3),
                  values.allSatisfy({ (0 ... 1).contains($0) }),
                  let strongest = values.max(),
                  strongest > 0 else {
                return nil
            }

            // Canonical RGB magnitudes do not encode light intensity. Match
            // the engine by normalizing the nonlinear sRGB components before
            // applying the sRGB electro-optical transfer function.
            let red = sRGBToLinear(values[0] / strongest)
            let green = sRGBToLinear(values[1] / strongest)
            let blue = sRGBToLinear(values[2] / strongest)
            return ParsedColor(
                xyz: XYZ(
                    x: (0.4124564 * red)
                        + (0.3575761 * green)
                        + (0.1804375 * blue),
                    y: (0.2126729 * red)
                        + (0.7151522 * green)
                        + (0.0721750 * blue),
                    z: (0.0193339 * red)
                        + (0.1191920 * green)
                        + (0.9503041 * blue)
                ),
                whiteKelvin: nil
            )

        case "White":
            guard let kelvin = entry.value.numberValue,
                  let xyz = whiteXYZ(kelvin: kelvin) else {
                return nil
            }
            return ParsedColor(
                xyz: xyz,
                whiteKelvin: min(25_000, max(1_667, kelvin))
            )

        case "XY":
            guard let values = numericArray(entry.value, count: 2),
                  (0 ... 1).contains(values[0]),
                  values[1] > 0,
                  values[1] <= 1,
                  values[0] + values[1] <= 1,
                  let xyz = xyz(
                    chromaticity: (x: values[0], y: values[1])
                  ) else {
                return nil
            }
            return ParsedColor(xyz: xyz, whiteKelvin: nil)

        default:
            return nil
        }
    }

    static func whiteXYZ(kelvin: Double) -> XYZ? {
        guard let chromaticity = blackBodyChromaticity(kelvin: kelvin) else {
            return nil
        }
        return xyz(chromaticity: chromaticity)
    }

    static func normalizedOKLabPoint(from xyz: XYZ) -> Point? {
        let l = (0.8189330101 * xyz.x)
            + (0.3618667424 * xyz.y)
            - (0.1288597137 * xyz.z)
        let m = (0.0329845436 * xyz.x)
            + (0.9293118715 * xyz.y)
            + (0.0361456387 * xyz.z)
        let s = (0.0482003018 * xyz.x)
            + (0.2643662691 * xyz.y)
            + (0.6338517070 * xyz.z)
        let lRoot = cbrt(l)
        let mRoot = cbrt(m)
        let sRoot = cbrt(s)
        let lightness = (0.2104542553 * lRoot)
            + (0.7936177850 * mRoot)
            - (0.0040720468 * sRoot)
        let a = (1.9779984951 * lRoot)
            - (2.4285922050 * mRoot)
            + (0.4505937099 * sRoot)
        let b = (0.0259040371 * lRoot)
            + (0.7827717662 * mRoot)
            - (0.8086757660 * sRoot)
        guard lightness.isFinite,
              lightness > 0,
              a.isFinite,
              b.isFinite else {
            return nil
        }
        return Point(x: a / lightness, y: b / lightness)
    }

    static func makeChromaticViewportImage(
        center: Point,
        halfSpan: Double,
        size: Int
    ) -> CGImage? {
        guard size > 0, halfSpan > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let lightness = 0.78

        for row in 0 ..< size {
            let vertical = ((Double(row) + 0.5) / Double(size) * 2) - 1
            for column in 0 ..< size {
                let horizontal = ((Double(column) + 0.5)
                    / Double(size) * 2) - 1
                let point = Point(
                    x: center.x + (horizontal * halfSpan),
                    y: center.y + (vertical * halfSpan)
                )
                guard let rgb = gamutMappedDisplayP3(
                    lightness: lightness,
                    point: point
                ) else {
                    continue
                }
                let offset = ((row * size) + column) * 4
                pixels[offset] = encodedByte(fromLinear: rgb.red)
                pixels[offset + 1] = encodedByte(fromLinear: rgb.green)
                pixels[offset + 2] = encodedByte(fromLinear: rgb.blue)
                pixels[offset + 3] = 255
            }
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let provider = CGDataProvider(
                data: Data(pixels) as CFData
              ) else {
            return nil
        }
        return CGImage(
            width: size,
            height: size,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.last.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .relativeColorimetric
        )
    }

    static func displayP3(from xyz: XYZ) -> RGB? {
        valid(
            RGB(
                red: (2.4934969 * xyz.x)
                    - (0.9313836 * xyz.y)
                    - (0.4027108 * xyz.z),
                green: (-0.8294890 * xyz.x)
                    + (1.7626640 * xyz.y)
                    + (0.0236247 * xyz.z),
                blue: (0.0358458 * xyz.x)
                    - (0.0761724 * xyz.y)
                    + (0.9568845 * xyz.z)
            )
        )
    }

    static func linearSRGB(from xyz: XYZ) -> RGB? {
        valid(
            RGB(
                red: (3.2404542 * xyz.x)
                    - (1.5371385 * xyz.y)
                    - (0.4985314 * xyz.z),
                green: (-0.9692660 * xyz.x)
                    + (1.8760108 * xyz.y)
                    + (0.0415560 * xyz.z),
                blue: (0.0556434 * xyz.x)
                    - (0.2040259 * xyz.y)
                    + (1.0572252 * xyz.z)
            )
        )
    }

    static func brightestInGamut(_ rgb: RGB) -> RGB? {
        // Negative components are outside the destination gamut. Project to
        // its boundary, then normalize the strongest channel. This keeps the
        // single-color readout intensity-independent.
        let components = rgb.components.map { max(0, $0) }
        guard let strongest = components.max(), strongest > 0 else {
            return nil
        }
        return RGB(
            red: components[0] / strongest,
            green: components[1] / strongest,
            blue: components[2] / strongest
        )
    }

    private static func gamutMappedDisplayP3(
        lightness: Double,
        point: Point
    ) -> RGB? {
        func color(chromaScale: Double) -> RGB? {
            displayP3(
                from: xyz(
                    okLabLightness: lightness,
                    normalizedPoint: Point(
                        x: point.x * chromaScale,
                        y: point.y * chromaScale
                    )
                )
            )
        }

        if let requested = color(chromaScale: 1), isInGamut(requested) {
            return requested
        }

        // Project out-of-gamut samples toward neutral at constant OKLab
        // lightness. Unlike component clipping, this preserves hue throughout
        // the color-wheel viewport.
        var lower = 0.0
        var upper = 1.0
        for _ in 0 ..< 18 {
            let candidate = (lower + upper) / 2
            if let rgb = color(chromaScale: candidate), isInGamut(rgb) {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        guard let mapped = color(chromaScale: lower) else { return nil }
        return RGB(
            red: min(1, max(0, mapped.red)),
            green: min(1, max(0, mapped.green)),
            blue: min(1, max(0, mapped.blue))
        )
    }

    private static func xyz(
        okLabLightness lightness: Double,
        normalizedPoint: Point
    ) -> XYZ {
        let a = normalizedPoint.x * lightness
        let b = normalizedPoint.y * lightness
        let lRoot = lightness + (0.3963377774 * a) + (0.2158037573 * b)
        let mRoot = lightness - (0.1055613458 * a) - (0.0638541728 * b)
        let sRoot = lightness - (0.0894841775 * a) - (1.2914855480 * b)
        let l = lRoot * lRoot * lRoot
        let m = mRoot * mRoot * mRoot
        let s = sRoot * sRoot * sRoot
        return XYZ(
            x: (1.2270138511 * l)
                - (0.5577999807 * m)
                - (0.2812561490 * s),
            y: (-0.0405801784 * l)
                + (1.1122568696 * m)
                - (0.0716766787 * s),
            z: (-0.0763812845 * l)
                - (0.4214819784 * m)
                + (1.5861632204 * s)
        )
    }

    private static func numericArray(
        _ value: HBJSONValue,
        count: Int
    ) -> [Double]? {
        guard let values = value.arrayValue,
              values.count == count else {
            return nil
        }
        let numbers = values.compactMap(\.numberValue)
        guard numbers.count == count,
              numbers.allSatisfy(\.isFinite) else {
            return nil
        }
        return numbers
    }

    private static func xyz(
        chromaticity: (x: Double, y: Double)
    ) -> XYZ? {
        guard chromaticity.x.isFinite,
              chromaticity.y.isFinite,
              chromaticity.y > 0 else {
            return nil
        }

        // Y is deliberately one: Color is independent of the device's
        // intensity control, and presentation chooses display lightness.
        let luminance = 1.0
        let x = luminance * chromaticity.x / chromaticity.y
        let z = luminance
            * (1 - chromaticity.x - chromaticity.y)
            / chromaticity.y
        guard x.isFinite, z.isFinite, z >= 0 else { return nil }
        return XYZ(x: x, y: luminance, z: z)
    }

    private static func blackBodyChromaticity(
        kelvin: Double
    ) -> (x: Double, y: Double)? {
        guard kelvin.isFinite, kelvin > 0 else { return nil }

        // The same Planckian-locus approximation used by the engine for
        // cross-mode color projection.
        let temperature = min(25_000, max(1_667, kelvin))
        let x: Double
        if temperature <= 4_000 {
            x = (-0.2661239e9 / pow(temperature, 3))
                - (0.2343580e6 / pow(temperature, 2))
                + (0.8776956e3 / temperature)
                + 0.179910
        } else {
            x = (-3.0258469e9 / pow(temperature, 3))
                + (2.1070379e6 / pow(temperature, 2))
                + (0.2226347e3 / temperature)
                + 0.240390
        }

        let y: Double
        if temperature <= 2_222 {
            y = (-1.1063814 * pow(x, 3))
                - (1.34811020 * pow(x, 2))
                + (2.18555832 * x)
                - 0.20219683
        } else if temperature <= 4_000 {
            y = (-0.9549476 * pow(x, 3))
                - (1.37418593 * pow(x, 2))
                + (2.09137015 * x)
                - 0.16748867
        } else {
            y = (3.0817580 * pow(x, 3))
                - (5.87338670 * pow(x, 2))
                + (3.75112997 * x)
                - 0.37001483
        }

        guard x.isFinite,
              y.isFinite,
              (0 ... 1).contains(x),
              y > 0,
              y <= 1,
              x + y <= 1 else {
            return nil
        }
        return (x, y)
    }

    private static func valid(_ rgb: RGB) -> RGB? {
        rgb.components.allSatisfy(\.isFinite) ? rgb : nil
    }

    private static func isInGamut(_ rgb: RGB) -> Bool {
        rgb.components.allSatisfy { component in
            component.isFinite && (0 ... 1).contains(component)
        }
    }

    private static func encodedByte(fromLinear component: Double) -> UInt8 {
        let encoded = component <= 0.0031308
            ? 12.92 * component
            : (1.055 * pow(component, 1 / 2.4)) - 0.055
        return UInt8((min(1, max(0, encoded)) * 255).rounded())
    }

    private static func sRGBToLinear(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}
