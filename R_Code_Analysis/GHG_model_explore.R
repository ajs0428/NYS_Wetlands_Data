library(tidyverse)
library(sf)
library(terra)
library(corrplot)
library(lme4)
library(lmerTest)
library(MuMIn)
library(mgcv)
library(DHARMa)

# ---------------------------------------------------------------------------
# 0. Data prep
# ---------------------------------------------------------------------------
# NOTE: many of the field/soil columns come out of the gpkg as *character*
# ("Top10cm_perc_OM", water table, soil temp, ...). na.omit() therefore does
# not drop their missing values and they are silently unusable as predictors.
# Coerce them explicitly.
chr_to_num <- c(
  "Amb_CH4",
  "Amb_CO2",
  "pw_NH3_N_mg_L",
  "surf_NH3_N_mg_L",
  "pw_NO3_2_N_mg_L",
  "surf_NO3_2_N_mg_L",
  "pw_SRP_mg_L",
  "surf_SRP_mg_L",
  "pw_Acidified_SRP_mg_L",
  "Top6cm_perc_OM",
  "Top6cm_DryWeight_g_cc",
  "Top10cm_perc_OM",
  "Top10cm_DryWeight_g_cc",
  "Top20cm_perc_OM",
  "Top20cm_DryWeight_g_cc",
  "mean_pH",
  "mean_soil_temp",
  "mean_water_temp",
  "mean_DO_percent",
  "average_depth_to_water_table",
  "average_depth_to_water_table_over_20",
  "fraction_standing_water",
  "Water_Table_Category_score_average",
  "mean_woody_cover_abund",
  "mean_graminoids_abund",
  "mean_forbs_abund",
  "mean_non_vascular_abund",
  "mean_bare_ground_abund",
  "species_richness",
  "growth_habit_richness",
  "mean_veg_height"
)

d_raw <- st_read(
  "Data/FieldData/GHG/NYDEC_GHG_Sites_6347_ExtractedPredictors.gpkg",
  quiet = TRUE
) |>
  as_tibble() |>
  mutate(across(any_of(chr_to_num), ~ suppressWarnings(as.numeric(.x))))

# --- response construction -------------------------------------------------
# CH4_avg is strongly right skewed with 12 small negative values
# (min = -0.0177, max = 13.59). Two usable responses:
#
#   CH4_pos   = CH4_avg + SHIFT   strictly positive -> Gamma / lognormal GLMM
#   CH4_r5    = sign(y)*|y|^(1/5) the true (odd) 5th root; keeps the negatives
#
# The old code had `CH4_avg_plus = CH4_avg + -0.02`, which SUBTRACTS 0.02 and
# leaves 27 values <= 0, and `(CH4_avg)^(1/5)`, which returns NaN for every
# negative value (R will not take a fractional power of a negative number).
SHIFT <- 0.02 # > |min(CH4_avg)|; min(CH4_pos) becomes 0.00234

d <- d_raw |>
  mutate(
    CH4_pos = CH4_avg + SHIFT,
    CH4_log = log(CH4_pos),
    CH4_r5 = sign(CH4_avg) * abs(CH4_avg)^(1 / 5), # odd root, negatives kept
    CH4_slog = sign(CH4_avg) * log1p(abs(CH4_avg)),
    Site_ID = as.factor(Site_ID),
    ndvi = (nir - r) / (nir + r),
    ndwi = (g - nir) / (g + nir),
    ndvi_lo = (nir_lo - r_lo) / (nir_lo + r_lo),
    ndwi_lo = (g_lo - nir_lo) / (g_lo + nir_lo)
  )

# Geomorphon classes 3, 4, 7, 10 have 1-4 observations each. Left as-is they
# make dredge produce unstable / singular fits and blow up the SEs. Lump
# anything with < 5 obs into "other" and use flats (1) as the reference.
geo_n <- table(d$Geomorph_local)
geo_rare <- names(geo_n)[geo_n < 5]
d <- d |>
  mutate(
    Geomorph_local = ifelse(
      as.character(Geomorph_local) %in% geo_rare,
      "other",
      as.character(Geomorph_local)
    ),
    Geomorph_local = relevel(factor(Geomorph_local), ref = "1")
  )
table(d$Geomorph_local)

# Coarse 2-level version. Class 9 (valley) is the only geomorphon level that is
# ever significant, and dropping to 2 levels is what makes Geomorph x continuous
# interactions estimable -- see section 1b.
d <- d |>
  mutate(
    Geo2 = factor(
      ifelse(Geomorph_local == "9", "valley", "other"),
      levels = c("other", "valley")
    )
  )

# Raster-derived predictors (the ones available for wall-to-wall inference)
rast_vars <- c(
  "DEM",
  "slope_local",
  "TPI_local",
  "meanc_local",
  "dmv_local",
  "flowacc",
  "twi",
  "CHM",
  "pct_below_1m",
  "pct_1m_to_5m",
  "pct_above_5m",
  "ndvi",
  "ndwi",
  "ndvi_lo",
  "ndwi_lo",
  "r_lo",
  "g_lo",
  "b_lo",
  "nir_lo"
)
# Field/soil predictors (NOT mappable, but see section 4)
soil_vars <- c(
  "Top10cm_DryWeight_g_cc",
  "Top10cm_perc_OM",
  "Water_Table_Category_score_average",
  "fraction_standing_water"
)

# Subset columns BEFORE na.omit so unrelated missing columns don't cost rows
d_mod <- d |>
  select(
    Site_ID,
    Round_Number,
    CH4_avg,
    CH4_pos,
    CH4_log,
    CH4_r5,
    CH4_slog,
    Geomorph_local,
    Geo2,
    all_of(rast_vars)
  ) |>
  na.omit() |>
  droplevels()

d_soil <- d |>
  select(
    Site_ID,
    Round_Number,
    CH4_avg,
    CH4_pos,
    CH4_log,
    CH4_r5,
    CH4_slog,
    Geomorph_local,
    Geo2,
    all_of(rast_vars),
    all_of(soil_vars)
  ) |>
  na.omit() |>
  droplevels()

cat("n raster-only:", nrow(d_mod), " sites:", nlevels(d_mod$Site_ID), "\n")
cat("n with soil:  ", nrow(d_soil), " sites:", nlevels(d_soil$Site_ID), "\n")

# --- how much R2m is even achievable? --------------------------------------
# Every raster predictor is extracted at the site location, so it is CONSTANT
# across the two sampling rounds at a site. The fixed effects can therefore
# only ever explain BETWEEN-site variance; the within-site (round-to-round)
# variance is unreachable noise. The ICC is the hard ceiling on R2 marginal.
m_null <- lmer(CH4_log ~ 1 + (1 | Site_ID), data = d_mod)
vc <- as.data.frame(VarCorr(m_null))
cat(
  "\nICC =",
  round(vc$vcov[1] / sum(vc$vcov), 3),
  "<- theoretical max R2m from site-level predictors\n"
)

# --- correlation screen ----------------------------------------------------
d_num <- d_mod |> select(CH4_log, all_of(rast_vars))
corrplot::corrplot(cor(d_num), tl.cex = 0.7)

sort(cor(d_num)[-1, 1]) |> round(3) # nothing above |r| ~ 0.3

# ---------------------------------------------------------------------------
# 1. Dredge: report R2 and drop singular / non-converged fits
# ---------------------------------------------------------------------------
# MuMIn::dredge has an `extra` argument that takes a function of the fitted
# model and appends its (named, numeric) return values as columns. Use it to
# carry R2m/R2c and a singularity flag through, then subset on those columns.
extra_stats <- function(m) {
  r2 <- tryCatch(
    suppressWarnings(MuMIn::r.squaredGLMM(m)),
    error = function(e) matrix(NA_real_, 1, 2)
  )
  # r.squaredGLMM returns >1 row for some GLMM families (delta / lognormal /
  # trigamma). Prefer the "delta" row when present.
  i <- if (!is.null(rownames(r2)) && "delta" %in% rownames(r2)) "delta" else 1L
  sing <- tryCatch(as.numeric(lme4::isSingular(m)), error = function(e) {
    NA_real_
  })
  msg <- tryCatch(
    length(m@optinfo$conv$lme4$messages),
    error = function(e) NA_real_
  )
  # Rank deficiency matters more than singularity for factor x continuous
  # terms: lme4 silently DROPS columns and fits a different model than the one
  # you wrote, with only a warning. Flag it explicitly.
  rankdef <- tryCatch(
    {
      X <- lme4::getME(m, "X")
      ncol(X) - qr(X)$rank
    },
    error = function(e) NA_real_
  )
  c(
    R2m = unname(r2[i, 1]),
    R2c = unname(r2[i, 2]),
    singular = sing,
    conv_warn = as.numeric(msg),
    rankdef = as.numeric(rankdef)
  )
}

# The original 4-way interaction generates 16 fixed terms for n = 88 with only
# 45 independent sites. Capped at 2-way interactions and 6 terms.
mod_full <- lmer(
  CH4_log ~
    Geomorph_local +
    (pct_below_1m + ndwi_lo + dmv_local + twi)^2 +
    (1 | Site_ID),
  data = d_mod,
  REML = FALSE,
  na.action = "na.fail"
)
summary(mod_full)

dredge_mods <- MuMIn::dredge(
  mod_full,
  rank = "AICc",
  m.lim = c(1, 6),
  extra = extra_stats
)
# dredge prefixes the extra columns with the function name, so they arrive as
# extra_stats.R2m / .R2c / .singular / .conv_warn. Do NOT rename them with
# names(): a model.selection object keys its "column.types" attribute on the
# column names, and renaming orphans it (the df column then prints as 0 and
# get.models breaks). Just refer to the prefixed names.
head(dredge_mods, 10) # now carries R2m, R2c, singular, conv_warn

# Keep only clean fits, then re-rank. Use MuMIn's own subset method with
# recalc.delta/recalc.weights rather than assigning to the columns directly --
# `$<-` strips the "model.selection" class and breaks get.models() downstream.
dredge_ok <- subset(
  dredge_mods,
  extra_stats.singular == 0 &
    extra_stats.conv_warn == 0 &
    extra_stats.rankdef == 0,
  recalc.weights = TRUE,
  recalc.delta = TRUE
)

cat(
  "\ndredged:",
  nrow(dredge_mods),
  " singular/non-converged dropped:",
  nrow(dredge_mods) - nrow(dredge_ok),
  "\n"
)
head(dredge_ok, 10)

# Best clean model, and the best clean model that also clears an R2m threshold
best <- MuMIn::get.models(dredge_ok, subset = 1)[[1]]
summary(best)
MuMIn::r.squaredGLMM(best)

# Best clean model that also clears an R2m threshold -- empty for raster-only
subset(dredge_ok, extra_stats.R2m > 0.4) |> head()

# ---------------------------------------------------------------------------
# 1b. Can Geomorph_local interact with a continuous predictor?
# ---------------------------------------------------------------------------
# Short answer: yes -- singularity is NOT the binding constraint here. With
# ICC = 0.60 and 45 sites the random intercept is strongly identified, and no
# Geomorph x continuous model below collapses it (site SD stays 0.69-1.26).
# Two other things bite first.

# (a) RANK DEFICIENCY. On the *unlumped* 10-level factor, lme4 silently drops
#     4 columns: classes 3, 4, 7 and 10 have 1-4 obs from 1-2 sites, so they
#     get no interaction slope at all. You get a warning, not an error, and
#     the fitted model is not the one you wrote. This is what extra_stats'
#     rankdef flag catches.
#
# (b) NO WITHIN-LEVEL VARIATION IN X. Because every raster predictor is
#     site-constant, each distinct value appears exactly twice (once per
#     round), and pct_below_1m is piled up at its bound: 44 of 90 obs are
#     exactly 1.0. Count the distinct values available per level:
d_mod |>
  group_by(Geomorph_local) |>
  summarise(
    n_obs = n(),
    n_sites = n_distinct(Site_ID),
    distinct_pct = n_distinct(round(pct_below_1m, 6)),
    distinct_dmv = n_distinct(round(dmv_local, 6))
  ) |>
  as.data.frame()
# The "other" level has only 2 distinct pct_below_1m values across 5 sites.
# A slope fitted to 2 points is estimable but meaningless -- the resulting
# coefficient is 14.7 +/- 14.2:
mod_geo_int <- lmer(
  CH4_log ~ Geomorph_local * pct_below_1m + (1 | Site_ID),
  data = d_mod,
  REML = FALSE
)
isSingular(mod_geo_int) # FALSE -- it fits fine, it just isn't informative
round(summary(mod_geo_int)$coefficients, 3)

# (c) So the fix is to make the factor coarse enough that every level has real
#     spread in x. Class 9 (valley) is the only level that is ever significant,
#     so collapse to valley vs not. This buys back the df AND improves AICc:
geo_compare <- function(label, form) {
  m <- suppressWarnings(lmer(form, data = d_mod, REML = FALSE))
  r2 <- suppressWarnings(MuMIn::r.squaredGLMM(m))
  X <- getME(m, "X")
  data.frame(
    model = label,
    df = attr(logLik(m), "df"),
    AICc = MuMIn::AICc(m),
    R2m = r2[1, 1],
    singular = isSingular(m),
    rankdef = ncol(X) - qr(X)$rank
  )
}
rbind(
  geo_compare(
    "5-lvl Geo + dmv*twi  [sec.1 best]",
    CH4_log ~ Geomorph_local + dmv_local * twi + (1 | Site_ID)
  ),
  geo_compare(
    "5-lvl Geo*pct + dmv*twi",
    CH4_log ~ Geomorph_local * pct_below_1m + dmv_local * twi + (1 | Site_ID)
  ),
  geo_compare(
    "5-lvl Geo*(pct+dmv+twi)",
    CH4_log ~ Geomorph_local * (pct_below_1m + dmv_local + twi) + (1 | Site_ID)
  ),
  geo_compare(
    "Geo2 + dmv*twi",
    CH4_log ~ Geo2 + dmv_local * twi + (1 | Site_ID)
  ),
  geo_compare(
    "Geo2*pct + dmv*twi",
    CH4_log ~ Geo2 * pct_below_1m + dmv_local * twi + (1 | Site_ID)
  ),
  geo_compare(
    "Geo2*dmv + twi",
    CH4_log ~ Geo2 * dmv_local + twi + (1 | Site_ID)
  )
) |>
  arrange(AICc) |>
  print(row.names = FALSE, digits = 4)

# Best of both: Geo2 * pct_below_1m + dmv_local * twi is non-singular, full
# rank, and beats the section-1 winner on AICc (344.2 vs 350.5) while raising
# R2m from 0.235 to 0.280.
mod_geo2 <- lmer(
  CH4_log ~ Geo2 * pct_below_1m + dmv_local * twi + (1 | Site_ID),
  data = d_mod,
  REML = FALSE,
  na.action = "na.fail"
)
summary(mod_geo2)
MuMIn::r.squaredGLMM(mod_geo2)

# Dredge that candidate set with the same clean-fit filter
dredge_geo2 <- MuMIn::dredge(
  lmer(
    CH4_log ~ Geo2 * (pct_below_1m + dmv_local + twi) + (1 | Site_ID),
    data = d_mod,
    REML = FALSE,
    na.action = "na.fail"
  ),
  rank = "AICc",
  m.lim = c(1, 6),
  extra = extra_stats
)
dredge_geo2_ok <- subset(
  dredge_geo2,
  extra_stats.singular == 0 &
    extra_stats.conv_warn == 0 &
    extra_stats.rankdef == 0,
  recalc.weights = TRUE,
  recalc.delta = TRUE
)
head(dredge_geo2_ok, 10)

# ---------------------------------------------------------------------------
# 2. Which family fits the CH4 distribution?
# ---------------------------------------------------------------------------
# AIC from models fitted to *different transforms of y* is not comparable
# without a Jacobian correction. For a model on T = t(y),
#   logLik_y = logLik_T + sum(log|dT/dy|)  =>  AIC_y = AIC_T - 2*sum(log|dT/dy|)
# This puts every candidate back on the raw CH4_avg scale so AIC is comparable.
y <- d_mod$CH4_avg
J_identity <- 0
J_log <- sum(-log(d_mod$CH4_pos)) # T = log(y + SHIFT)
J_r5 <- sum(log(1 / 5) - (4 / 5) * log(abs(y))) # T = sign(y)|y|^(1/5)

fam_rhs <- "Geomorph_local + dmv_local + ndvi_lo + pct_below_1m + twi + (1|Site_ID)"
ff <- function(lhs) as.formula(paste(lhs, "~", fam_rhs))

fam_fit <- function(label, expr, J) {
  m <- try(suppressWarnings(eval(expr)), silent = TRUE)
  if (inherits(m, "try-error")) {
    return(data.frame(
      model = label,
      AIC_native = NA,
      AIC_raw = NA,
      R2m = NA,
      R2c = NA,
      singular = NA,
      nwarn = NA
    ))
  }
  r2 <- tryCatch(
    suppressWarnings(MuMIn::r.squaredGLMM(m)),
    error = function(e) matrix(NA_real_, 1, 2)
  )
  data.frame(
    model = label,
    AIC_native = AIC(m),
    AIC_raw = AIC(m) - 2 * J,
    R2m = r2[1, 1],
    R2c = r2[1, 2],
    singular = isSingular(m),
    nwarn = length(m@optinfo$conv$lme4$messages)
  )
}

fam_tab <- rbind(
  fam_fit(
    "lmer  identity",
    quote(lmer(ff("CH4_avg"), d_mod, REML = FALSE)),
    J_identity
  ),
  fam_fit(
    "lmer  log(y+0.02)",
    quote(lmer(ff("CH4_log"), d_mod, REML = FALSE)),
    J_log
  ),
  fam_fit(
    "lmer  signed 5th root",
    quote(lmer(ff("CH4_r5"), d_mod, REML = FALSE)),
    J_r5
  ),
  fam_fit(
    "glmer Gamma(log)",
    quote(glmer(ff("CH4_pos"), d_mod, family = Gamma(link = "log"))),
    J_identity
  ),
  fam_fit(
    "glmer Gamma(inverse)",
    quote(glmer(ff("CH4_pos"), d_mod, family = Gamma(link = "inverse"))),
    J_identity
  ),
  fam_fit(
    "glmer inverse.gaussian(log)",
    quote(glmer(ff("CH4_pos"), d_mod, family = inverse.gaussian(link = "log"))),
    J_identity
  ),
  fam_fit(
    "glmer gaussian(log)",
    quote(glmer(ff("CH4_pos"), d_mod, family = gaussian(link = "log"))),
    J_identity
  )
)
fam_tab[order(fam_tab$AIC_raw), ] |> print(row.names = FALSE, digits = 4)

# Result: Gamma(log) on the shifted response wins on Jacobian-corrected AIC,
# with lognormal (= lmer on log(y + SHIFT)) a close second. The signed 5th root
# is a distant third and identity-scale Gaussian is hopeless.
# Watch the `singular` / `nwarn` columns before believing any R2:
#   Gamma(inverse)  is a boundary fit -- Site_ID variance collapses to zero,
#                   so R2m == R2c == 0.571 is an artefact, not a good model.
#   gaussian(log)   reports R2m = 0.94 but AIC is ~275 units worse than
#                   Gamma(log). R2 here is computed on the raw, heavily skewed
#                   response, where getting the handful of very large fluxes
#                   roughly right dominates the sum of squares. This is the
#                   reason to rank on AIC and use R2 only within a family.
#   inverse.gaussian(log) converges but is far too heavy tailed.
mod_g <- glmer(
  CH4_pos ~
    Geomorph_local +
    dmv_local * ndvi_lo +
    pct_below_1m +
    (1 | Site_ID),
  data = d_mod,
  family = Gamma(link = "log"),
  na.action = "na.fail"
)
summary(mod_g)
MuMIn::r.squaredGLMM(mod_g)

# Residual check that is actually valid for a GLMM (raw resid vs fitted is not)
sim_g <- DHARMa::simulateResiduals(mod_g, n = 1000)
plot(sim_g)
DHARMa::testDispersion(sim_g)
DHARMa::testQuantiles(sim_g)

# Same check for the lognormal alternative
mod_ln <- lmer(
  CH4_log ~
    Geomorph_local + dmv_local * ndvi_lo + pct_below_1m + (1 | Site_ID),
  data = d_mod,
  REML = FALSE
)
plot(DHARMa::simulateResiduals(mod_ln, n = 1000))

# glmmTMB gives Tweedie / student-t / dispersion models that lme4 cannot fit.
# Useful if the Gamma dispersion test above fails.
if (requireNamespace("glmmTMB", quietly = TRUE)) {
  library(glmmTMB)
  tmb_gamma <- glmmTMB(
    ff("CH4_pos"),
    d_mod,
    family = Gamma(link = "log")
  )
  tmb_tw <- glmmTMB(ff("CH4_pos"), d_mod, family = tweedie(link = "log"))
  # dispersion allowed to vary by geomorphon
  tmb_disp <- glmmTMB(
    ff("CH4_pos"),
    d_mod,
    family = Gamma(link = "log"),
    dispformula = ~Geomorph_local
  )
  print(AIC(tmb_gamma, tmb_tw, tmb_disp))
}

# ---------------------------------------------------------------------------
# 3. GAM
# ---------------------------------------------------------------------------
# Use the same Gamma(log) family the GLMM comparison picked, keep Site_ID as a
# random effect smooth, and turn on `select = TRUE` so smooths that carry no
# signal can be shrunk to zero (this is the GAM analogue of dredge and is
# safer than stepwise selection at n = 90).
gam_rhs <- paste(
  "s(dmv_local, k = 4) + s(ndvi_lo, k = 4) + s(pct_below_1m, k = 4) +",
  "s(twi, k = 4) + Geomorph_local + s(Site_ID, bs = 're')"
)

mod_gam <- gam(
  as.formula(paste("CH4_pos ~", gam_rhs)),
  data = d_mod,
  family = Gamma(link = "log"),
  method = "REML",
  select = TRUE
)
summary(mod_gam)
gam.check(mod_gam) # k' vs edf; k = 4 is adequate here
plot(mod_gam, pages = 1, shade = TRUE, scale = 0)
# DHARMa on an mgcv gam needs mgcViz for the simulation step; gam.check()
# above already gives the QQ / resid-vs-fitted panels if it is not installed.
if (requireNamespace("mgcViz", quietly = TRUE)) {
  plot(DHARMa::simulateResiduals(mod_gam, n = 1000))
}

# Score conditional vs marginal fit on the LOG scale so the numbers are
# comparable to the GLMM R2m/R2c (response-scale R2 under a log link is
# dominated by the handful of very large fluxes and is not informative).
r2 <- function(y, mu) 1 - sum((y - mu)^2) / sum((y - mean(y))^2)

gam_r2 <- function(m, dat, resp = "CH4_log") {
  lp <- predict(m, type = "link")
  lpm <- predict(m, type = "link", exclude = "s(Site_ID)")
  if (is.matrix(lp)) {
    lp <- lp[, 1]
    lpm <- lpm[, 1]
  }
  c(
    AIC = AIC(m),
    dev_expl = summary(m)$dev.expl,
    R2c = r2(dat[[resp]], lp),
    R2m = r2(dat[[resp]], lpm)
  )
}
gam_r2(mod_gam, d_mod)

# Family comparison for the GAM, all scored on the log-CH4 scale
gam_try <- function(fm, fam, dat, sel = TRUE) {
  m <- try(
    gam(fm, data = dat, family = fam, method = "REML", select = sel),
    silent = TRUE
  )
  if (inherits(m, "try-error")) rep(NA_real_, 4) else gam_r2(m, dat)
}
gam_tab <- rbind(
  `Gamma(log)` = gam_try(
    as.formula(paste("CH4_pos ~", gam_rhs)),
    Gamma(link = "log"),
    d_mod
  ),
  `tw(log)` = gam_try(
    as.formula(paste("CH4_pos ~", gam_rhs)),
    tw(link = "log"),
    d_mod
  ),
  gaussian_log = gam_try(
    as.formula(paste("CH4_log ~", gam_rhs)),
    gaussian(),
    d_mod
  ),
  scat_log = gam_try(as.formula(paste("CH4_log ~", gam_rhs)), scat(), d_mod),
  # location-scale models: log(sigma) allowed to vary. `select` must be off.
  gaulss_log = gam_try(
    list(as.formula(paste("CH4_log ~", gam_rhs)), ~ s(dmv_local, k = 4)),
    gaulss(),
    d_mod,
    sel = FALSE
  ),
  gammals = gam_try(
    list(as.formula(paste("CH4_pos ~", gam_rhs)), ~ s(dmv_local, k = 4)),
    gammals(),
    d_mod,
    sel = FALSE
  )
)
round(gam_tab, 3)
# Note: gaulss/gammals are fragile at this n - gammals reports "step failure"
# and its AIC is not trustworthy. Gamma(log) is the stable choice.

# ---------------------------------------------------------------------------
# 4. Getting R2m > 0.4
# ---------------------------------------------------------------------------
# Raster-only predictors cannot get there: the best single raster predictor
# correlates |r| ~ 0.3 with log CH4 at the site level, and the ICC caps R2m at
# ~0.6 anyway. Soil bulk density and the water table score are much stronger
# (|r| = 0.53 and 0.48) and do clear the threshold.
soil_screen <- sapply(
  c(rast_vars, soil_vars),
  function(v) cor(d_soil$CH4_log, d_soil[[v]], method = "spearman")
)
sort(soil_screen) |> round(3)

mod_soil <- glmer(
  CH4_pos ~
    Top10cm_DryWeight_g_cc +
    Water_Table_Category_score_average +
    Geomorph_local +
    (1 | Site_ID),
  data = d_soil,
  family = Gamma(link = "log"),
  na.action = "na.fail"
)
summary(mod_soil)
MuMIn::r.squaredGLMM(mod_soil) # R2m ~ 0.61, R2c ~ 0.80
isSingular(mod_soil)
plot(DHARMa::simulateResiduals(mod_soil, n = 1000))

# GAM version, raster + soil
mod_gam_soil <- gam(
  as.formula(paste(
    "CH4_pos ~",
    gam_rhs,
    "+ s(Top10cm_DryWeight_g_cc, k = 4)",
    "+ s(Water_Table_Category_score_average, k = 4)"
  )),
  data = d_soil,
  family = Gamma(link = "log"),
  method = "REML",
  select = TRUE
)
summary(mod_gam_soil)
gam_r2(mod_gam_soil, d_soil) # R2m ~ 0.60

# Dredge the soil model set the same way as section 1
mod_soil_full <- glmer(
  CH4_pos ~
    (Top10cm_DryWeight_g_cc +
      Water_Table_Category_score_average +
      fraction_standing_water)^2 +
    Geomorph_local +
    dmv_local +
    twi +
    (1 | Site_ID),
  data = d_soil,
  family = Gamma(link = "log"),
  na.action = "na.fail"
)
dredge_soil <- MuMIn::dredge(
  mod_soil_full,
  rank = "AICc",
  m.lim = c(1, 5),
  extra = extra_stats
)
dredge_soil_ok <- subset(
  dredge_soil,
  extra_stats.singular == 0 &
    extra_stats.conv_warn == 0 &
    extra_stats.rankdef == 0,
  recalc.weights = TRUE,
  recalc.delta = TRUE
)
head(dredge_soil_ok, 10)
subset(dredge_soil_ok, extra_stats.R2m > 0.4) |> head(10)
