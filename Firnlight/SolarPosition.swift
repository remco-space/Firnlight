import Foundation

/// Where the sun stood, for a moment and a place on Earth.
///
/// FR-5.13's worked example: nothing here is measured off a photo, and nothing
/// is looked up. It is astronomy the app carries, applied to the instant and
/// coordinate a photo already records, and it turns those into the traits the
/// ranker can actually learn a taste over — how low the light was, and which
/// way it came from relative to where the camera looked.
///
/// Elevation is the variable golden hour is really about: "golden hour" names
/// a sun a few degrees above the horizon, not a clock time, and the same clock
/// time means completely different light in June and December, or in Zermatt
/// and Sydney. Deriving elevation collapses time-of-day, time-of-year and
/// hemisphere into the one quantity that governs how the light looks.
///
/// The algorithm is NOAA's low-precision solar position calculation, accurate
/// to about a hundredth of a degree over the years a photo library spans —
/// several orders of magnitude finer than a preference for "low sun" needs. It
/// ignores atmospheric refraction (which lifts the apparent disc by roughly
/// half a degree near the horizon) and observer altitude; both matter for
/// predicting the exact instant of sunrise and neither matters for placing a
/// photo on a scale of how low the light was.
///
/// `nonisolated`: pure arithmetic, called from the ranker's actor.
nonisolated enum SolarPosition {
    /// Elevation above the horizon and azimuth clockwise from true north,
    /// both in degrees, plus the hour angle (negative before solar noon,
    /// positive after — the only thing that separates a sunrise from a sunset
    /// of identical elevation).
    struct Angles: Sendable {
        /// Degrees above the horizon; negative when the sun has set.
        let elevation: Double
        /// Degrees clockwise from true north, 0…360.
        let azimuth: Double
        /// Degrees from solar noon, −180…180. Negative is morning.
        let hourAngle: Double
    }

    private static let degreesPerRadian = 180 / Double.pi

    static func angles(date: Date, latitude: Double, longitude: Double) -> Angles {
        // Days since the J2000.0 epoch, the argument every term below takes.
        let julianDay = date.timeIntervalSince1970 / 86400 + 2440587.5
        let n = julianDay - 2451545.0

        let meanLongitude = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let meanAnomaly = (357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360)
        // Ecliptic longitude: the mean position corrected for the Earth's
        // orbit being an ellipse rather than a circle.
        let eclipticLongitude = meanLongitude
            + 1.915 * sin(radians(meanAnomaly)) + 0.020 * sin(radians(2 * meanAnomaly))
        let obliquity = 23.439 - 0.0000004 * n

        let declination = asin(
            sin(radians(obliquity)) * sin(radians(eclipticLongitude))
        ) * degreesPerRadian
        let rightAscension = atan2(
            cos(radians(obliquity)) * sin(radians(eclipticLongitude)),
            cos(radians(eclipticLongitude))
        ) * degreesPerRadian

        // Equation of time — how far true solar time runs ahead of or behind
        // mean time, up to about ±16 minutes across the year.
        var equationOfTime = (4 * (meanLongitude - rightAscension))
            .truncatingRemainder(dividingBy: 1440)
        if equationOfTime > 720 { equationOfTime -= 1440 }
        if equationOfTime < -720 { equationOfTime += 1440 }

        // Longitude, not a time zone: a photo carries an absolute instant and
        // a coordinate, never the zone it was taken in — and civil zones are
        // political anyway, offset from the sun by up to hours and shifted
        // again by daylight saving. Four minutes per degree is the sun's own
        // clock.
        let utcMinutes = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) / 60
        let trueSolarTime = (utcMinutes + 4 * longitude + equationOfTime)
            .truncatingRemainder(dividingBy: 1440)
        var hourAngle = trueSolarTime / 4 - 180
        if hourAngle < -180 { hourAngle += 360 }
        if hourAngle > 180 { hourAngle -= 360 }

        let sinElevation = sin(radians(latitude)) * sin(radians(declination))
            + cos(radians(latitude)) * cos(radians(declination)) * cos(radians(hourAngle))
        let elevation = asin(min(1, max(-1, sinElevation))) * degreesPerRadian

        let cosAzimuth = (sin(radians(declination)) - sin(radians(latitude)) * sin(radians(elevation)))
            / (cos(radians(latitude)) * cos(radians(elevation)))
        var azimuth = acos(min(1, max(-1, cosAzimuth))) * degreesPerRadian
        // acos cannot tell morning from afternoon; the hour angle can.
        if hourAngle > 0 { azimuth = 360 - azimuth }

        return Angles(elevation: elevation, azimuth: azimuth, hourAngle: hourAngle)
    }

    private static func radians(_ degrees: Double) -> Double { degrees / degreesPerRadian }
}
