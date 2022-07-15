"""
Lobster model based on
2005 A four-dimensional mesoscale map of the spring bloom in the northeast Atlantic (POMME experiment): Results of a prognostic model
2001 Impact of sub-mesoscale physics on production and subduction of phytoplankton in an oligotrophic regime
2012How does dynamical spatial variability impact 234Th-derived estimates of organic export
using flux boundary condition
ignore aggregation term 
annual cycle 
add callback to diagnose pCO2
"""

using Random
using Printf
using Plots
using JLD2
using NetCDF
using HDF5
using Interpolations
using Statistics

using Oceananigans#9e8cae18-63c1-5223-a75c-80ca9d6e9a09
using Oceananigans.Units: second,minute, minutes, hour, hours, day, days, year, years

using Lobster

params = Lobster.default

######## 1: import annual cycle physics data  #Global Ocean 1/12° Physics Analysis and Forecast updated Daily
filename1 = "subpolar_physics.nc" # subtropical_physics.nc  subpolar_physics.nc
#ncinfo(filename1)
time_series_second = (0:364)days # start from zero if we don't use extrapolation, we cannot use extrapolation if we wana use annual cycle  
so = ncread(filename1, "so");  #salinity
so_scale_factor = ncgetatt(filename1, "so", "scale_factor") #Real_Value = (Display_Value X scale_factor) + add_offset
so_add_offset = ncgetatt(filename1, "so", "add_offset")
salinity = mean(so, dims=(1,2))[1:365]*so_scale_factor.+so_add_offset # use [1:365] cause sometimes one year has 366 days. 
salinity_itp = LinearInterpolation(time_series_second, salinity) 
#converted to interpolations to access them at arbitary time, how to use it: salinity_itp(mod(timeinseconds,364days))
#plot(salinity)
thetao = ncread(filename1, "thetao");  #temperature
thetao_scale_factor = ncgetatt(filename1, "thetao", "scale_factor") 
thetao_add_offset = ncgetatt(filename1, "thetao", "add_offset")
temperature = mean(thetao, dims=(1,2))[1:365]*thetao_scale_factor.+thetao_add_offset
temperature_itp = LinearInterpolation(time_series_second, temperature)  
#plot(temperature)
mlotst = ncread(filename1, "mlotst"); #mixed_layer_depth
mlotst_scale_factor = ncgetatt(filename1, "mlotst", "scale_factor") 
mlotst_add_offset = ncgetatt(filename1, "mlotst", "add_offset")
mixed_layer_depth = mean(mlotst, dims=(1,2))[1:365]*mlotst_scale_factor.+mlotst_add_offset
mld_itp = LinearInterpolation(time_series_second, mixed_layer_depth)  
#plot(mixed_layer_depth)

######## 2: import annual cycle chl data  #Global Ocean Biogeochemistry Analysis and Forecast
filename2 = "subpolar_chl.nc"    #subpolar_chl.nc
chl = ncread(filename2, "chl");  #chl scale_factor=1 add_offset=0
chl_mean = mean(chl, dims=(1,2))[1,1,:,1:365] # mg m-3, unit no need to change. 
depth_chl = ncread(filename2, "depth");
#heatmap(1:365, -depth_chl[end:-1:1], chl_mean[end:-1:1,:])

######## 3: import annual cycle PAR data #Ocean Color  VIIRS-SNPP PAR daily 9km
path="./subpolar/"    #subtropical   #./subpolar/
par_mean_timeseries=zeros(1,365)
for i in 1:365    #https://discourse.julialang.org/t/leading-zeros/30450
    string_i = lpad(string(i), 3, '0')
    filename3=path*"V2020"*string_i*".L3b_DAY_SNPP_PAR.x.nc"
    fid = h5open(filename3, "r")
    par=read(fid["level-3_binned_data/par"])
    BinList=read(fid["level-3_binned_data/BinList"])  #(:bin_num, :nobs, :nscenes, :weights, :time_rec) 
    par_mean_timeseries[1,i] = mean([par[i][1]/BinList[i][4] for i in 1:length(par)])*3.99e-10*545e12/(1day)  #from einstin/m^2/day to W/m^2
end

#PAR with depth
PAR = zeros(length(depth_chl),365)
PAR_r = zeros(length(depth_chl),365)
PAR_b = zeros(length(depth_chl),365)

PAR[1,:] = par_mean_timeseries
PAR_r[1,:] = par_mean_timeseries/2
PAR_b[1,:] = par_mean_timeseries/2
for i =2:length(depth_chl)
    PAR_r[i,:]=PAR_r[i-1,:].*exp.(-(params.k_r0.+params.Χ_rp*(chl_mean[i-1,:]).^params.e_r)*(depth_chl[i]-depth_chl[i-1]))
    PAR_b[i,:]=PAR_b[i-1,:].*exp.(-(params.k_b0.+params.Χ_bp*(chl_mean[i-1,:]).^params.e_b)*(depth_chl[i]-depth_chl[i-1]))
    PAR[i,:]=PAR_b[i,:]+PAR_r[i,:]
end
#heatmap(1:365, -depth_chl[end:-1:1], PAR[end:-1:1,:])
PAR_itp = Interpolations.interpolate((-depth_chl[end:-1:1], (0:364)day), PAR[end:-1:1,:], Gridded(Linear()))
PAR_extrap = extrapolate(PAR_itp, (Line(),Throw()))  #  PAR_extrap(z, mod(t,364days))  Interpolations.extrapolate Method

# Simulation duration    30days years
duration=2years    #2years
# Define the grid

Lx = 1   #500
Ly = 500
Nx = 1
Ny = 1
Nz = 150 # number of points in the vertical direction
Lz = 600 # domain depth             # subpolar mixed layer depth max 427m 

grid = RectilinearGrid(
                size=(Nx, Ny, Nz), 
                extent=(Lx, Ly, Lz))

B₀ = 0e-8    #m²s⁻³  B₀ = 4.24e-8  
N² = 9e-6    #dbdz=N^2, s⁻²
buoyancy_bcs = FieldBoundaryConditions(top = FluxBoundaryCondition(B₀),
                                       bottom = GradientBoundaryCondition(N²))

########## u boundary condition                                
u₁₀ = 0     # m s⁻¹, average wind velocity 10 meters above the ocean
cᴰ = 2.5e-3  # dimensionless drag coefficient
ρₒ = 1026 # kg m⁻³, average density at the surface of the world ocean
ρₐ = 1.225   # kg m⁻³, average density of air at sea-level
Qᵘ = - ρₐ / ρₒ * cᴰ * u₁₀ * abs(u₁₀) # m² s⁻²
u_bcs = FieldBoundaryConditions(top = FluxBoundaryCondition(Qᵘ))

bgc_tracers, bgc_forcing, bgc_boundaries = Lobster.lobster(grid, params)

#κₜ(x, y, z, t) = 1e-2*max(1-(z+50)^2/50^2,0)+1e-5;
κₜ(x, y, z, t) = 1e-2*max(1-(z+mld_itp(mod(t,364days))/2)^2/(mld_itp(mod(t,364days))/2)^2,0)+1e-5;

#for now I'm going to make the fields not be forced at all by Oceanigans, and then use a call back to update them once a day (see below)
no_forcing(x, y, z, t) = 0
t_forcing = Forcing(no_forcing)
s_forcing = Forcing(no_forcing)
par_forcing = Forcing(no_forcing)

t_bcs = FieldBoundaryConditions(top = FluxBoundaryCondition(0), bottom = FluxBoundaryCondition(0))
s_bcs = FieldBoundaryConditions(top = FluxBoundaryCondition(0), bottom = FluxBoundaryCondition(0))
par_bcs = FieldBoundaryConditions(top = FluxBoundaryCondition(0), bottom = FluxBoundaryCondition(0))

###Model instantiation
model = NonhydrostaticModel(advection = UpwindBiasedFifthOrder(),
                            timestepper = :RungeKutta3,
                            grid = grid,
                            tracers = (bgc_tracers..., :b, :T, :S, :PAR),
                            coriolis = FPlane(f=1e-4),
                            buoyancy = BuoyancyTracer(), 
                            closure = ScalarDiffusivity(ν=κₜ, κ=κₜ), 
                            forcing = merge((T=t_forcing, S=s_forcing, PAR=par_forcing), bgc_forcing),
                            boundary_conditions = merge((u=u_bcs, b=buoyancy_bcs, T=t_bcs, S=s_bcs, PAR=par_bcs), bgc_boundaries))

## Random noise damped at top and bottom
Ξ(z) = randn() * z / model.grid.Lz * (1 + z / model.grid.Lz) # noise


#set initial conditions
initial_mixed_layer_depth = -100 # m
stratification(z) = z < initial_mixed_layer_depth ? N² * z : N² * (initial_mixed_layer_depth)
bᵢ(x, y, z) = stratification(z)         #+ 1e-1 * Ξ(z) * N² * model.grid.Lz

Pᵢ(x,y,z)= (tanh((z+250)/100)+1)/2*(0.038)+0.002          # ((tanh((z+100)/50)-1)/2*0.23+0.23)*16/106  
Zᵢ(x,y,z)= (tanh((z+250)/100)+1)/2*(0.038)+0.008          # ((tanh((z+100)/50)-1)/2*0.3+0.3)*16/106         
Dᵢ(x,y,z)=0
DDᵢ(x,y,z)=0
NO₃ᵢ(x,y,z)= (1-tanh((z+300)/150))/2*6+11.4   #  # 17.5*(1-tanh((z+100)/10))/2
NH₄ᵢ(x,y,z)= (1-tanh((z+300)/150))/2*0.05+0.05       #1e-1*(1-tanh((z+100)/10))/2
DOMᵢ(x,y,z)= 0 
DICᵢ(x,y,z)= 2380   #  mmol/m^-3
ALKᵢ(x,y,z)= 2720   #  mmol/m^-3

PARᵢ(x,y,z) =  PAR_extrap(z, 0)

## `set!` the `model` fields using functions or constants:
set!(model, b=bᵢ, P=Pᵢ, Z=Zᵢ, D=Dᵢ, DD=DDᵢ, NO₃=NO₃ᵢ, NH₄=NH₄ᵢ, DOM=DOMᵢ,DIC=DICᵢ,ALK=ALKᵢ, u=0, v=0, w=0, T=temperature_itp(0), S=salinity_itp(0), PAR = PARᵢ)

# ## Setting up a simulation

simulation = Simulation(model, Δt=200, stop_time=duration)  #Δt=0.5*(Lz/Nz)^2/1e-2,

#now sorting out T/S/PAR fields
#Not sure this is a very efficent way of doing this
function update_fields(sim)
    sim.model.tracers.T .= temperature_itp(mod(sim.model.clock.time, 364days)) .+ 273.15
    sim.model.tracers.S .= salinity_itp(mod(sim.model.clock.time, 364days))

    for (k, z) in enumerate(Oceananigans.Grids.znodes(Center,grid))
        sim.model.tracers.PAR[:, :, k] .= PAR_extrap(z, mod(sim.model.clock.time, 364days))
    end
end

simulation.callbacks[:update_fields] = Callback(update_fields)


## Print a progress message
progress_message(sim) = @printf("Iteration: %04d, time: %s, Δt: %s, wall time: %s\n",
                                iteration(sim),
                                prettytime(sim),
                                prettytime(sim.Δt),
                                prettytime(sim.run_wall_time))

simulation.callbacks[:progress] = Callback(progress_message, IterationInterval(100))
#=
#this can move into Lobster.jl at some point
pco2_bc = zeros(2,round(Int,duration/1day)+3)   #Int(duration/simulation.Δt)
function pco2(sim)  #https://clima.github.io/OceananigansDocumentation/stable/generated/baroclinic_adjustment/
    #i+=1
    pco2_bc[2,round(Int,sim.model.clock.time/1day)+1] = Lobster.air_sea_flux(1, 1, sim.model.clock.time, model.tracers.DIC[1,1,end-3], model.tracers.ALK[1,1,end-3], params)*(1years/1000)/(7.7e-4*params.U_10^2)+params.pCO2_air   #1×1×150 Field
    pco2_bc[1,round(Int,sim.model.clock.time/1day)+1] = sim.model.clock.time/1day
    #sim.model.clock.iteration
end 

simulation.callbacks[:pco2] = Callback(pco2, IterationInterval(Int(1day/simulation.Δt))) #callback every 1 day 
=#

# We then set up the simulation:

# Vertical slice
simulation.output_writers[:profiles] =
    JLD2OutputWriter(model, merge(model.velocities, model.tracers),
                          filename = "profile_subpolar3.jld2",
                          indices = (1, 1, :),
                          schedule = TimeInterval(1days),     #TimeInterval(1days),
                            overwrite_existing = true)

#simulation.output_writers[:particles] = JLD2OutputWriter(model, (particles=model.particles,), 
#                            prefix = "particles",
#                          schedule = TimeInterval(1minute),
#                             force = true)

# We're ready:

run!(simulation)
#jldsave("pco2_water_subpolar.jld2"; pco2_bc)  
#jldopen("pco2_water_subpolar.jld2", "r")


# ## Turbulence visualization
#
# We animate the data saved in `ocean_wind_mixing_and_convection.jld2`.
# We prepare for animating the flow by creating coordinate arrays,
# opening the file, building a vector of the iterations that we saved
# data at, and defining functions for computing colorbar limits:

## Coordinate arrays
xw, yw, zw = nodes(model.velocities.w)
xb, yb, zb = nodes(model.tracers.b)

## Open the file with our data
file_profiles = jldopen(simulation.output_writers[:profiles].filepath)
#file_flux = jldopen(simulation.output_writers[:flux].filepath)

## Extract a vector of iterations
iterations = parse.(Int, keys(file_profiles["timeseries/t"]))

# We start the animation at `t = 10minutes` since things are pretty boring till then:

times = [file_profiles["timeseries/t/$iter"] for iter in iterations]
intro = searchsortedfirst(times, 10minutes)

NO₃_save=zeros(Nz,size(iterations)[1]);  #zeros(Nz,size(iterations)[1]-1)
NH₄_save=zeros(Nz,size(iterations)[1]);
P_save=zeros(Nz,size(iterations)[1]);
Z_save=zeros(Nz,size(iterations)[1]);
DOM_save=zeros(Nz,size(iterations)[1]);
D_save=zeros(Nz,size(iterations)[1]);
DD_save=zeros(Nz,size(iterations)[1]);
DIC_save=zeros(Nz,size(iterations)[1]);
ALK_save=zeros(Nz,size(iterations)[1]);
Budget_save=zeros(Nz,size(iterations)[1]);
time_save=zeros(size(iterations)[1])

#global flux_save=zeros(size(iterations)[1]-1);

anim = @animate for (i, iter) in enumerate(iterations)   #iterations[intro:end]

    @info "Drawing frame $i from iteration $iter..."

    t = file_profiles["timeseries/t/$iter"]
    time_save[i]=t;

    #T = file_profiles["timeseries/T/$iter"][1, 1, :]
    #S = file_profiles["timeseries/S/$iter"][1, 1, :]
    NO₃ = file_profiles["timeseries/NO₃/$iter"][1, 1, :]
    NH₄ = file_profiles["timeseries/NH₄/$iter"][1, 1, :]
    P = file_profiles["timeseries/P/$iter"][1, 1, :]
    Z = file_profiles["timeseries/Z/$iter"][1, 1, :]
    D = file_profiles["timeseries/D/$iter"][1, 1, :]
    DD = file_profiles["timeseries/DD/$iter"][1, 1, :]
    DOM = file_profiles["timeseries/DOM/$iter"][1, 1, :]
    DIC = file_profiles["timeseries/DIC/$iter"][1, 1, :]
    ALK = file_profiles["timeseries/ALK/$iter"][1, 1, :]
    Budget = NO₃ .+ NH₄ .+ P .+ Z .+ D .+ DD .+ DOM
    #flux = file_flux["timeseries/flux/$iter"][1, 1, Nz]

    NO₃_save[:,i] = NO₃[:]; 
    NH₄_save[:,i] = NH₄[:];
    P_save[:,i] = P[:]; 
    Z_save[:,i] = Z[:]; 
    D_save[:,i] = D[:]; 
    DD_save[:,i] = DD[:]; 
    DOM_save[:,i] = DOM[:]
    DIC_save[:,i] = DIC[:]
    ALK_save[:,i] = ALK[:]
    Budget_save[:,i] = Budget[:]
    #flux_save[i] = flux[1]

    NO₃_plot = plot(NO₃, zb; ylabel="z(m)")
    NH₄_plot = plot(NH₄, zb; ylabel="z(m)")
    P_plot = plot(P, zb; ylabel="z(m)")
    Z_plot = plot(Z, zb; ylabel="z(m)")
    D_plot = plot(D, zb; ylabel="z(m)")
    DD_plot = plot(DD, zb; ylabel="z(m)")
    DOM_plot = plot(DOM, zb; ylabel="z(m)")
    DIC_plot = plot(DIC, zb; ylabel="z(m)")
    ALK_plot = plot(ALK, zb; ylabel="z(m)")
    #flux_plot = plot(time_save[1:i],flux_save[1:i]; ylabel="flux")
    #Budget_plot = plot(Budget, zb; ylabel="z(m)")

    NO₃_title = @sprintf("Nitrate , t = %s", prettytime(t)) #"nitrate"
    NH₄_title = "ammonium"
    P_title = "phytoplankton"
    Z_title = "zooplankton"
    D_title = "Detritus"
    DD_title = "Large Detritus"
    DOM_title = "dissolved organic matter"
    DIC_title = "DIC"
    ALK_title = @sprintf("ALK, N budget = %s", sum(Budget))
    #Budget_title = @sprintf("N budget, total = %s", sum(Budget))
    #flux_title = @sprintf("Flux = %s (mol/m^2/y)", flux)
    ## Arrange the plots side-by-side.
    plot(NO₃_plot, NH₄_plot, P_plot, Z_plot, D_plot, DD_plot, DOM_plot, DIC_plot, ALK_plot,layout=(3, 3), size=(2400, 1000),
         title=[NO₃_title NH₄_title P_title Z_title D_title DD_title DOM_title DIC_title ALK_title]) # S doesn't change much
   

    #iter == iterations[end] && close(file)
end

#mp4(anim, "annual_cycle_subpolar_highinit.mp4", fps = 10) # hide

#close(file_profiles)

fs=4 # front size   #https://stackoverflow.com/questions/57976378/how-to-scale-the-fontsizes-using-plots-jl
kwargs = (xlabel="time (days)", ylabel="z (m)")
NO₃_map=heatmap(time_save/(1day),zb,NO₃_save,titlefontsize=fs, guidefontsize=fs,tickfontsize=fs,legendfontsize=fs, xlabel="time (days)", ylabel="z (m)", xlims=(0,365*2))
NH₄_map=heatmap(time_save/(1day),zb,NH₄_save,titlefontsize=fs, guidefontsize=fs,tickfontsize=fs,legendfontsize=fs, xlabel="time (days)", ylabel="z (m)", xlims=(0,365*2))
P_map=heatmap(time_save/(1day),zb,P_save,titlefontsize=fs, guidefontsize=fs,tickfontsize=fs,legendfontsize=fs, xlabel="time (days)", ylabel="z (m)", xlims=(0,365*2))
Z_map=heatmap(time_save/(1day),zb,Z_save,titlefontsize=fs, guidefontsize=fs,tickfontsize=fs,legendfontsize=fs, xlabel="time (days)", ylabel="z (m)", xlims=(0,365*2))
D_map=heatmap(time_save/(1day),zb,D_save,titlefontsize=fs, guidefontsize=fs,tickfontsize=fs,legendfontsize=fs, xlabel="time (days)", ylabel="z (m)", xlims=(0,365*2))
DD_map=heatmap(time_save/(1day),zb,DD_save,titlefontsize=fs, guidefontsize=fs,tickfontsize=fs,legendfontsize=fs, xlabel="time (days)", ylabel="z (m)", xlims=(0,365*2))
DOM_map=heatmap(time_save/(1day),zb,DOM_save,titlefontsize=fs, guidefontsize=fs,tickfontsize=fs,legendfontsize=fs, xlabel="time (days)", ylabel="z (m)", xlims=(0,365*2))
DIC_map=heatmap(time_save/(1day),zb,DIC_save,titlefontsize=fs, guidefontsize=fs,tickfontsize=fs,legendfontsize=fs, xlabel="time (days)", ylabel="z (m)", xlims=(0,365*2))
ALK_map=heatmap(time_save/(1day),zb,ALK_save,titlefontsize=fs, guidefontsize=fs,tickfontsize=fs,legendfontsize=fs, xlabel="time (days)", ylabel="z (m)", xlims=(0,365*2))
#Budget_map=heatmap(time_save/(1day),zb,Budget_save,xlabel="time (days)", ylabel="z (m)", xlims=(0,365*2))
plot(NO₃_map,NH₄_map,P_map,Z_map,D_map,DD_map,DOM_map,DIC_map,ALK_map,title=["Nitrate" "Ammonium" "Phytoplankton" "Zooplankton" "Detritus" "Large Detritus" "DOM" "DIC" "ALK"])
#savefig("annual_cycle_subpolar_highinit.pdf")