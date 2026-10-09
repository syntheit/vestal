import Foundation

// MARK: - The astro source
//
// Sun and moon for a place, computed offline from `latitude` and
// `longitude`. The sun follows NOAA's solar calculator
// (https://gml.noaa.gov/grad/solcalc/calcdetails.html, after Jean Meeus,
// Astronomical Algorithms): the equation of time and the declination at
// local solar noon give sunrise and sunset for the official zenith of
// 90.833 degrees (the sun's radius and atmospheric refraction), good to
// about a minute away from the poles. The moon is the mean synodic month
// counted from a known new moon (2000-01-06 18:14 UTC), which is within about
// half a day of the real phases: enough to say "full in 4d".
//
// The data, for the local calendar day of `now`:
//
//   { latitude, longitude, date: "2026-09-27",
//     sunrise, sunset, solarNoon,            // epoch seconds; null in polar day/night
//     dayLength, dayLengthChange,            // seconds; the change against yesterday
//     polar,                                 // null, "day" (sun never sets) or "night" (never rises)
//     arc,                                   // the sun's altitude in degrees, 49 samples from sunrise to sunset; null when polar
//     peak,                                  // the highest altitude today, degrees
//     moon: { phase, age, illumination, name, nextFull, nextNew, daysToFull, daysToNew } }
//
// `phase` is 0 to 1 (0 new, 0.5 full), `age` days since the new moon,
// `illumination` percent 0 to 100, the `next…` times epoch seconds.

public enum Astro {
    /// The zenith of sunrise and sunset: 90 degrees plus the sun's radius
    /// and refraction at the horizon.
    static let horizonZenith = 90.833
    /// The mean synodic month in days, and a new moon to count from (JD of 2000-01-06 18:14 UTC).
    static let synodicMonth = 29.530588853
    static let referenceNewMoon = 2451550.1
    static let arcSamples = 49

    public struct Sun: Equatable, Sendable {
        /// Epoch seconds; nil when the sun doesn't cross the horizon today.
        public var sunrise: Double?
        public var sunset: Double?
        public var solarNoon: Double
        /// "day" (never sets), "night" (never rises) or nil.
        public var polar: String?
        public var dayLength: Double
    }

    // MARK: Julian day

    /// The Julian day of epoch seconds.
    static func julianDay(_ epoch: Double) -> Double { epoch / 86400 + 2440587.5 }

    // MARK: Sun

    /// Equation of time (minutes) and declination (degrees) at a Julian day.
    static func solarPosition(julianDay jd: Double) -> (equationOfTime: Double, declination: Double) {
        let t = (jd - 2451545) / 36525
        func rad(_ d: Double) -> Double { d * .pi / 180 }
        let l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let c = sin(rad(m)) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(rad(2 * m)) * (0.019993 - 0.000101 * t) + sin(rad(3 * m)) * 0.000289
        let apparent = l0 + c - 0.00569 - 0.00478 * sin(rad(125.04 - 1934.136 * t))
        let obliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
            + 0.00256 * cos(rad(125.04 - 1934.136 * t))
        let declination = asin(sin(rad(obliquity)) * sin(rad(apparent))) * 180 / .pi
        let y = pow(tan(rad(obliquity) / 2), 2)
        let eq = y * sin(2 * rad(l0)) - 2 * e * sin(rad(m)) + 4 * e * y * sin(rad(m)) * cos(2 * rad(l0))
            - 0.5 * y * y * sin(4 * rad(l0)) - 1.25 * e * e * sin(2 * rad(m))
        return (4 * eq * 180 / .pi, declination)
    }

    /// Sunrise, sunset and solar noon for the calendar date `year-month-day`
    /// at the place. The date is the one at the place's local solar noon,
    /// which is also its UTC date for every longitude.
    public static func sun(latitude: Double, longitude: Double, year: Int, month: Int, day: Int) -> Sun {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        let midnight = utc.date(from: DateComponents(year: year, month: month, day: day))?.timeIntervalSince1970 ?? 0
        // Declination and the equation of time at solar noon (twice: the
        // first pass places noon).
        var noon = 720 - 4 * longitude
        var position = solarPosition(julianDay: julianDay(midnight + noon * 60))
        noon = 720 - 4 * longitude - position.equationOfTime
        position = solarPosition(julianDay: julianDay(midnight + noon * 60))
        noon = 720 - 4 * longitude - position.equationOfTime
        let lat = latitude * .pi / 180, decl = position.declination * .pi / 180
        let cosHour = cos(horizonZenith * .pi / 180) / (cos(lat) * cos(decl)) - tan(lat) * tan(decl)
        let solarNoon = midnight + noon * 60
        if cosHour > 1 { return Sun(sunrise: nil, sunset: nil, solarNoon: solarNoon, polar: "night", dayLength: 0) }
        if cosHour < -1 { return Sun(sunrise: nil, sunset: nil, solarNoon: solarNoon, polar: "day", dayLength: 86400) }
        let hour = acos(cosHour) * 180 / .pi
        // The sun moves 4 minutes per degree; the declination is that of noon.
        let rise = midnight + (noon - 4 * hour) * 60, set = midnight + (noon + 4 * hour) * 60
        return Sun(sunrise: rise, sunset: set, solarNoon: solarNoon, polar: nil, dayLength: set - rise)
    }

    /// The sun's altitude above the horizon in degrees (no refraction) at an
    /// instant.
    public static func altitude(latitude: Double, longitude: Double, epoch: Double) -> Double {
        let position = solarPosition(julianDay: julianDay(epoch))
        var utcMinutes = (epoch / 60).truncatingRemainder(dividingBy: 1440)
        if utcMinutes < 0 { utcMinutes += 1440 }
        var solarTime = (utcMinutes + position.equationOfTime + 4 * longitude).truncatingRemainder(dividingBy: 1440)
        if solarTime < 0 { solarTime += 1440 }
        let hourAngle = (solarTime / 4 - 180) * .pi / 180
        let lat = latitude * .pi / 180, decl = position.declination * .pi / 180
        let cosZenith = sin(lat) * sin(decl) + cos(lat) * cos(decl) * cos(hourAngle)
        return 90 - acos(min(max(cosZenith, -1), 1)) * 180 / .pi
    }

    // MARK: Moon

    public struct Moon: Equatable, Sendable {
        /// 0 (new) to 1; 0.5 is full.
        public var phase: Double
        /// Days since the new moon.
        public var age: Double
        /// Percent of the disc lit, 0 to 100.
        public var illumination: Double
        public var name: String
        /// Epoch seconds.
        public var nextFull: Double
        public var nextNew: Double
    }

    public static let phaseNames = ["New moon", "Waxing crescent", "First quarter", "Waxing gibbous",
                                    "Full moon", "Waning gibbous", "Last quarter", "Waning crescent"]

    public static func moon(epoch: Double) -> Moon {
        let days = julianDay(epoch) - referenceNewMoon
        var age = days.truncatingRemainder(dividingBy: synodicMonth)
        if age < 0 { age += synodicMonth }
        let phase = age / synodicMonth
        let illumination = (1 - cos(2 * .pi * phase)) / 2 * 100
        let name = phaseNames[Int((phase * 8).rounded()) % 8]
        let toFull = ((0.5 - phase) + 1).truncatingRemainder(dividingBy: 1) * synodicMonth
        let toNew = (1 - phase) * synodicMonth
        return Moon(phase: phase, age: age, illumination: illumination, name: name,
                    nextFull: epoch + toFull * 86400, nextNew: epoch + toNew * 86400)
    }

    // MARK: The source's data

    /// The `astro` shape for the local calendar day of `now` in `calendar`.
    public static func data(latitude: Double, longitude: Double, now: Date, calendar: Calendar) -> AnyJSON {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let year = parts.year ?? 1970, month = parts.month ?? 1, day = parts.day ?? 1
        let today = sun(latitude: latitude, longitude: longitude, year: year, month: month, day: day)
        let yesterdayDate = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let before = calendar.dateComponents([.year, .month, .day], from: yesterdayDate)
        let yesterday = sun(latitude: latitude, longitude: longitude,
                            year: before.year ?? year, month: before.month ?? month, day: before.day ?? day)
        func time(_ value: Double?) -> AnyJSON { value.map { .int(Int($0.rounded())) } ?? .null }
        var arc: AnyJSON = .null
        var peak = altitude(latitude: latitude, longitude: longitude, epoch: today.solarNoon)
        if let rise = today.sunrise, let set = today.sunset {
            let samples = (0..<arcSamples).map { i -> Double in
                let t = rise + (set - rise) * Double(i) / Double(arcSamples - 1)
                return max(0, altitude(latitude: latitude, longitude: longitude, epoch: t))
            }
            arc = .array(samples.map { .double(($0 * 100).rounded() / 100) })
            peak = samples.max() ?? peak
        }
        let moon = moon(epoch: now.timeIntervalSince1970)
        let nowEpoch = now.timeIntervalSince1970
        func rounded(_ value: Double, _ places: Double = 100) -> AnyJSON { .double((value * places).rounded() / places) }
        return .object([
            "latitude": .double(latitude),
            "longitude": .double(longitude),
            "date": .string(String(format: "%04d-%02d-%02d", year, month, day)),
            "sunrise": time(today.sunrise),
            "sunset": time(today.sunset),
            "solarNoon": time(today.solarNoon),
            "dayLength": .int(Int(today.dayLength.rounded())),
            "dayLengthChange": .int(Int((today.dayLength - yesterday.dayLength).rounded())),
            "polar": today.polar.map { .string($0) } ?? .null,
            "arc": arc,
            "peak": rounded(peak),
            "moon": .object([
                "phase": rounded(moon.phase, 1000),
                "age": rounded(moon.age, 10),
                "illumination": rounded(moon.illumination, 10),
                "name": .string(moon.name),
                "nextFull": time(moon.nextFull),
                "nextNew": time(moon.nextNew),
                "daysToFull": rounded((moon.nextFull - nowEpoch) / 86400, 10),
                "daysToNew": rounded((moon.nextNew - nowEpoch) / 86400, 10),
            ]),
        ])
    }
}
