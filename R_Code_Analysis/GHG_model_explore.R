library(tidyverse)
library(sf)
library(terra)
library(corrplot)
library(lme4)
library(lmerTest)
library(MuMIn)
library(mgcv)

d <- st_read(
  "Data/FieldData/GHG/NYDEC_GHG_Sites_6347_ExtractedPredictors.gpkg"
) |>
  as_tibble() |>
  mutate(
    Amb_CH4 = as.numeric(Amb_CH4),
    CH4_slog = sign(CH4_avg) * log1p(abs(CH4_avg)),
    CH4_avg_plus = CH4_avg + -0.02,
    Geomorph_local = as.factor(Geomorph_local),
    Site_ID = as.factor(Site_ID),
    ndvi = (nir - r) / (nir + r),
    ndwi = (g - nir) / (g + nir),
    ndvi_lo = (nir_lo - r_lo) / (nir_lo + r_lo),
    ndwi_lo = (g_lo - nir_lo) / (g_lo + nir_lo)
  ) |>
  na.omit()
glimpse(d)

ggplot(d, aes(x = Geomorph_local |> as.character(), y = CH4_avg_plus)) +
  geom_point() +
  geom_smooth(method = "lm", se = F)


d_num <- d |>
  select(where(is.numeric)) |>
  select(CH4_avg, c(25:49)) |>
  na.omit()

d_cor <- cor(d_num)

corrplot::corrplot(d_cor)

d_cor[, 1] |>
  as.data.frame() |>
  na.omit() |>
  rownames_to_column() |>
  rename("cor" = 2) |>
  arrange(desc(cor))


mod <- lmer(
  (CH4_avg_plus) ~ Geomorph_local +
    pct_below_1m *
      ndwi_lo *
      dmv_local *
      twi +
    (1 | Site_ID),
  data = d,
  REML = F,
  na.action = "na.fail"
)
summary(mod)

dredge_mods <- MuMIn::dredge(mod, rank = "AIC", m.lim = c(2, 12))
head(dredge_mods)
dm <- MuMIn::get.models(dredge_mods, subset = 1)[[1]]
summary(dm)
MuMIn::r.squaredGLMM(dm)


mod_p <- glmer(
  (CH4_avg) ~ dmv_local *
    ndvi_lo +
    Geomorph_local * pct_below_1m +
    (1 | Site_ID),
  family = Tweedie(),
  data = d # REML = F
)
summary(mod_p)
MuMIn::r.squaredGLMM(mod_p)
plot(fitted(mod_p), resid(mod_p))
hist(resid(mod_p))

plot(fitted(mod_p) ~ (d$CH4_avg))

mod_ls <- gam(
  list(
    CH4_slog ~ s(dmv_local, k = 4) +
      s(ndvi_lo, k = 4) +
      Geomorph_local +
      s(pct_below_1m, k = 4) +
      s(Site_ID, bs = "re"),
    ~ s(dmv_local, k = 4) # scale model: log(sigma)
  ),
  data = d,
  family = gaulss(),
  method = "REML"
)

summary(mod_ls)

y <- mod_ls$y

r2 <- function(y, mu) 1 - sum((y - mu)^2) / sum((y - mean(y))^2)

mu_cond <- predict(mod_ls, type = "response")[, 1]

mu_marg <- predict(mod_ls, type = "response", exclude = "s(Site_ID)")[, 1]

r2(y, mu_cond) # conditional — includes site effects
r2(y, mu_marg) # marginal — what raster inference actually delivers
