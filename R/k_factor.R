# K-factor calculation for AAVSO solar observers.
# R port of k-factor_calculator.pl (Sara J. Beck with Matthew Templeton, 2013).

library(DBI)
library(dplyr)

# Julian Date at 12:00 UT on a calendar date (matches the Perl script's
# mjd2jd(cal2mjd(day, month, year, 0.5))).
date_to_jd <- function(date) {
  as.numeric(as.Date(date)) + 2440588
}

jd_to_date <- function(jd) {
  as.Date(floor(jd + 0.5) - 2440588)
}

# Database connection settings.
SOLAR_DB_HOST <- "db.aavso.org"
SOLAR_DB_NAME <- "solar"
SOLAR_DB_USER <- "your_username"
SOLAR_DB_PASSWORD <- "your_password"

connect_solar_db <- function(host = SOLAR_DB_HOST, dbname = SOLAR_DB_NAME,
                             user = SOLAR_DB_USER, password = SOLAR_DB_PASSWORD) {
  dbConnect(RMariaDB::MariaDB(), host = host, dbname = dbname,
            user = user, password = password)
}

last_ra_jd <- function(con) {
  dbGetQuery(con, "SELECT MAX(jd) AS jd FROM sunspot_counts")$jd
}

# Every unrevised Wolf number reported in the period.
fetch_observations <- function(con, start_jd, end_jd) {
  dbGetQuery(con, "
    SELECT obs, W AS wolf, date AS jd
    FROM sun_data
    WHERE date >= ? AND date <= ? AND revised = 0",
    params = list(start_jd, end_jd))
}

# Reference sunspot numbers (Ra) for the period, one per JD.
fetch_ra <- function(con, start_jd, end_jd) {
  dbGetQuery(con, "
    SELECT jd, count AS ra
    FROM sunspot_counts
    WHERE jd >= ? AND jd <= ?",
    params = list(start_jd, end_jd)) |>
    distinct(jd, .keep_all = TRUE)
}

# Current (old) k-factor for every observer.
fetch_old_k <- function(con) {
  dbGetQuery(con, "SELECT obs, k AS old_k FROM sun_obsconst WHERE revised = 0") |>
    distinct(obs, .keep_all = TRUE)
}

# log10 that substitutes 0.1 for zero or missing values, as the Perl script does.
log10_or_substitute <- function(x) {
  ifelse(is.na(x) | x == 0, 0.1, log10(x))
}

# k = geometric mean of Ra / W over an observer's observations.
#
# zero_handling:
#   "substitute" - reproduce the Perl script: a zero or missing W or Ra
#                  contributes log10 = 0.1.
#   "skip"       - drop days where W or Ra is zero or missing.
# Observers qualify with min_obs observations in the period, counted before
# any days are skipped (as in the Perl script).
compute_k_factors <- function(observations, ra, min_obs = 100,
                              zero_handling = c("substitute", "skip")) {
  zero_handling <- match.arg(zero_handling)

  obs <- observations |>
    add_count(obs, name = "n_reported") |>
    filter(n_reported >= min_obs) |>
    left_join(ra, by = "jd") |>
    mutate(zero_or_missing = is.na(wolf) | wolf == 0 | is.na(ra) | ra == 0)

  if (zero_handling == "skip") {
    obs <- obs |>
      filter(!zero_or_missing) |>
      mutate(log_ratio = log10(ra) - log10(wolf))
  } else {
    obs <- obs |>
      mutate(log_ratio = log10_or_substitute(ra) - log10_or_substitute(wolf))
  }

  obs |>
    group_by(obs) |>
    summarise(
      n_reported = first(n_reported),
      n_used = n(),
      n_zero_or_missing = sum(zero_or_missing),
      k = 10^mean(log_ratio),
      .groups = "drop"
    ) |>
    arrange(obs)
}

write_k_factors <- function(k_factors, path = "new_k-factors.txt") {
  out <- data.frame(observer = k_factors$obs,
                    `K-factor` = sprintf("%.3f", k_factors$k),
                    check.names = FALSE)
  write.table(out, path, sep = "\t", quote = FALSE, row.names = FALSE)
  invisible(path)
}
