
# Setup
#####################################################################################

# Packages
library(raster)
library(tidyverse)
library(countrycode)
library(rnaturalearth)

# Directories
eezdir <- "data/eezs"
tempdir <- "data/template"
costdir <- "data/costs/data"
plotdir <- "data/costs/figures"

# Read raster template
ras_temp <- raster(file.path(tempdir, "world_raster_template_10km.tif"))

# Read EEZ raster and key
eezs <- raster(file.path(eezdir, "eezs_v10_raster_10km.tif"))
eezs_sf <- readRDS(file.path(eezdir, "eezs_v10_polygons.Rds"))
eez_key <- read.csv(file.path(eezdir, "eezs_v10_key.csv"), as.is=T)
compareRaster(eezs, ras_temp)

# World layer
world <- rnaturalearth::ne_countries(scale = "large", type = "countries", returnclass = "sf")

# Distance to shore (m) raster
cdist_km <- raster(file.path(costdir, "dist_to_coast_km_10km_inhouse.grd"))

# WB data
wb_costs <- read.csv(file.path(costdir, "eez_wb_diesel_income_costs.csv"), as.is=T)


# Number of farms per cell
#####################################################################################

# Number of farms per cells
cell_sqkm <- prod(res(eezs)/1000)
nfarms <- cell_sqkm


# 1. Calculate fuel costs
#####################################################################################

# Fuel cost parameters
# From Lester et al. 2018
vessel_n <- 2
vessel_lph <- 60.6 # vessel fuel efficiency, liters per hour (from 16 g/hr in Lester et al. 2018)
vessel_kmh <- 12.9 # vessel speed, km per hour (from 8 mph in Lester et al. 2018)
vessel_trips_yr <- 416 # two identical vessels - one making 5 trips/week and the other 3 trips/week (from Lester et al. 2018)

# Create fuel price raster
fuel_usd_l_ras <- reclassify(eezs, rcl=select(wb_costs, eez_code, diesel_usd_l))
# plot(fuel_usd_l_ras)

# Fuel cost raster
fuel_usd_yr_farm <- (2 * cdist_km) / vessel_kmh * vessel_lph * fuel_usd_l_ras * vessel_trips_yr

# Plot and export
if(F){
  
  # Quick plot
  plot(fuel_usd_yr_farm/1e6, main="Annual fuel cost per farm (USD millions)", xaxt="n", yaxt="n", 
       col=freeR::colorpal(rev(RColorBrewer::brewer.pal(n=9, name="RdYlBu")), 50))
  
  # Export data
  writeRaster(fuel_usd_yr_farm, file.path(costdir, "fuel_cost_per_farm.tif"), overwrite=T)
  
}


# 2. Calculate wage costs
#####################################################################################

# Labor cost parameters
# From Lester et al. 2018
worker_n <- 8 # 8 workers per farm
worker_hrs <- 2080 # 40 hour weeks x 52 weeks / year = 2080 hours / year (does not include transport time)

# Create wages raster
wb_costs$wages_usd_hr <- wb_costs$income_usd_yr / worker_hrs
wages_usd_hr_ras <- reclassify(eezs, rcl=select(wb_costs, eez_code, wages_usd_hr))

# Quick plot
# plot(wages_usd_hr_ras, main="Worker wages (USD per hour)", xaxt="n", yaxt="n",
#      col=freeR::colorpal(RColorBrewer::brewer.pal(n=9, name="RdYlBu"), 50))

# Calculate number of transit hours
transit_hrs_ras <- (2 * cdist_km) / vessel_kmh * vessel_trips_yr

# Calculate annnual wage cost per farm
wages_usd_yr_farm <- wages_usd_hr_ras * worker_n * (worker_hrs + transit_hrs_ras)

# Plot and export
if(F){
  
  # Quick plot
  plot(wages_usd_yr_farm/1e6, main="Annual wage cost per farm (USD millions)", xaxt="n", yaxt="n", 
       col=freeR::colorpal(rev(RColorBrewer::brewer.pal(n=9, name="RdYlBu")), 50))
  
  # Export data
  writeRaster(wages_usd_yr_farm, file.path(costdir, "wage_cost_per_farm.tif"), overwrite=T)
  
}


# Calculate variable costs
#####################################################################################

# Discount rate
disc_rate <- 0.1

# Annuity function
annuity <- function(c, r = 0.1, t = 10) {
  a <- c / ((1-(1+r)^-t)/r)
  return(a)
}



# Calculate capital costs
calc_cap_costs <- function(farm_design, harvest_yr){
  
  # Bivalve farms
  if(farm_design$type=="bivalve"){
    
    # Bivalve capital costs
    # From NOAA 2008
    ll_usd <- 10000
    ll_life_yr <- 10
    vessel_usd <- 95000
    vessel_life_yr <- 30
    
    # Amortized bivalve capital cost
    vessel_cap_cost_yr <- annuity(c=vessel_usd*vessel_n, r=disc_rate, t=vessel_life_yr) 
    ll_cap_cost_yr <- annuity(c=ll_usd*farm_design$nlines, r=disc_rate, t=ll_life_yr) 
    cap_cost_yr <- vessel_cap_cost_yr + ll_cap_cost_yr # total
    
  }
  
  # Finfish farms
  if(farm_design$type=="finfish"){
    
    # Finfish cages
    cage_n <- farm_design$ncages
    cage_m3 <- farm_design$cage_vol_m3
    cage_m3_tot <- cage_n * cage_m3
    
    # Fingerling costs
    # Amoretized over lifespan of juvenile (time to harvest)
    juv_per_farm <- farm_design$nstocked
    usd_per_juv <- 0.85 # NOAA 2008
    juv_cost_yr <- annuity(c=(juv_per_farm*usd_per_juv), r=disc_rate, t=harvest_yr)
    
    # Cage capital costs (NOAA 2008)
    # Amoretized over life span of cages
    cage_usd_m3 <- 15
    cage_install_usd_m3 <- 3
    cage_life_yr <- 10
    cage_cost_yr <- annuity(c=(cage_m3_tot*cage_usd_m3)+(cage_m3_tot*cage_install_usd_m3), r=disc_rate, t=cage_life_yr)
    
    # Total capital costs
    cap_cost_yr <- cage_cost_yr + juv_cost_yr
    
  }
  
  # Return
  return(cap_cost_yr)
  
}

# Calculate operational costs
calc_oper_costs <- function(farm_design){
  
  # Finfish farms
  if(farm_design$type=="finfish"){
    # Finfish operating costs (NOAA 2008)
    cage_m3_tot <- farm_design$ncages * farm_design$cage_vol_m3
    cage_maintain_usd_m3_yr <- 1
    cage_maintain_usd_yr <- cage_m3_tot * cage_maintain_usd_m3_yr
    vessel_usd_yr <- 100000
    onshore_usd_yr <- 150000
    insurance_usd_yr <- 50000
    opp_cost_yr <- vessel_usd_yr + onshore_usd_yr + insurance_usd_yr + cage_maintain_usd_yr
  }
  
  # Bivalve farms
  if(farm_design$type=="bivalve"){
    # Bivalve operating costs (NOAA 2008)
    misc_supp_usd <- 1700 * farm_design$nlines
    vessel_upkeep_usd <-  (10000 + 5000) * vessel_n
    onshore_usd <- 173000
    opp_cost_yr <- misc_supp_usd + vessel_upkeep_usd + onshore_usd # total
  }
  
  # Return
  return(opp_cost_yr)

}
  


# Calculate cost of production
calc_costs <- function(farm_design, cell_prod_mt_yr, fcr, vcells, harvest_yr){
  
  # Number of farms per cell
  cell_sqkm <- prod(res(vcells)) / (1000^2)
  cell_nfarms <- cell_sqkm / farm_design$area_sqkm
  
  # Calculate annualized capital costs per farm
  cap_usd_yr_farm <- calc_cap_costs(farm_design, harvest_yr)
  
  # Calculate annual operating costs (not fuel, wages, or feed) per farm
  oper_usd_yr_farm <- calc_oper_costs(farm_design)
  
  # Calculate annual feed cost for WHOLE CELL
  feed_usd_kg <- 2 # $/kg personal communication from Thomas et al. Caribbean mariculture paper
  feed_usd_mt <- feed_usd_kg * 1000
  feed_mt_yr <- cell_prod_mt_yr * fcr
  feed_usd_yr <- feed_mt_yr * feed_usd_mt
  
  # Calculate final costs
  cost_yr <- cell_nfarms * (cap_usd_yr_farm + fuel_usd_yr_farm + wages_usd_yr_farm + oper_usd_yr_farm) + feed_usd_yr 
  cost_yr_masked <- mask(cost_yr, vcells, maskvalue=NA)
  
  # Confirm that COST raster and SUITABILITY rasters have same number of values
  suit_ncells <- colSums(getValues(vcells), na.rm=T)
  cost_ncells <- colSums(!is.na(getValues(cost_yr_masked))) 
  if(sum(suit_ncells!=cost_ncells)!=0){
    stop("The cost raster does not have the same number of cells as the viable raster.")
  }
  
  # Return costs
  return(cost_yr_masked)
  
}