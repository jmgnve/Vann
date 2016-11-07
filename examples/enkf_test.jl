################################################################################

# Add packages

using RCall
using Distributions
using DataFrames
using Vann

################################################################################

if is_windows()
  path_inputs = "C:/Users/jmg/Dropbox/Work/VannData/Input";
  path_save   = "C:/Users/jmg/Dropbox/Work/VannData";
  path_param  = "C:/Users/jmg/Dropbox/Work/VannData/201611051410_Results"
end

################################################################################

# Folder for saving results

time_now = Dates.format(now(), "yyyymmddHHMM");

path_save = path_save * "/" * time_now * "_Results";

mkpath(path_save * "/calib_txt")
mkpath(path_save * "/calib_png")
mkpath(path_save * "/valid_txt")
mkpath(path_save * "/valid_png")

################################################################################

# Perturb input data for snow model

function perturb_input(st_snow, prec, tair, itime)

  n = Uniform(0.5, 1.5);
  prec_noise = rand(n, 1);

  n = Normal(0.0, 2);
  tair_noise = rand(n, 1);

  # Assign inputs to snow model

  for izone in eachindex(st_snow.prec)

    st_snow.prec[izone] = prec[izone, itime] * prec_noise[1];
    st_snow.tair[izone] = tair[izone, itime] + tair_noise[1];

  end

end

################################################################################

function enkf(state_ens, d_matrix, hx_matrix)

  # Variables (Mandel)

  X  = state_ens;
  D  = d_matrix;
  HX = hx_matrix;

  # Subtract ensemble mean (Mandel)

  (n, N) = size(X);
  (m, N) = size(D);

  A    = X - 1 / N * (X * ones(Float64, N, 1)) * ones(Float64, 1, N);
  HA   = HX - 1 / N * (HX * ones(Float64, N, 1)) * ones(Float64, 1, N);
  Dtmp = D - 1 / N * (D * ones(Float64, N, 1)) * ones(Float64, 1, N);

  # Observation error variance (Mandel-theoretic, Evensen-sample)

  R_sample = Dtmp * Dtmp' / (N-1);

  # Variance of predicted observations (DeChant and Mandel)

  C_YY = 1 / (N-1) * HA * HA';

  # Covariance between states ensemble and predicted observations (DeChant and Mandel)

  C_XY = 1 / (N-1) * A * HA';

  # Compute kalman gain (DeChant)

  K = C_XY / (C_YY + R_sample);

  if any(isnan(K))
    println("R_sample = $R_sample")
    println("C_YY = $C_YY")
    println("C_XY = $C_XY")
    error("Nans in Kalman gain")
  end

  # Update states (DeChant and Mandel)

  Xhat = X + K*(D-HX);

  return(Xhat);

end

################################################################################

# Ensemble kalman filter

function run_filter(prec, tair, epot, q_obs, param_snow, param_hydro, frac, nens)

  srand(1);

  # Number of elevation bands (rows) and time steps (cols)

  nzones = size(prec, 1);
  ntimes = size(prec, 2);

  # Initilize state variables

  st_snow  = [TinBasicType(param_snow, frac) for i in 1:nens];
  st_hydro = [Gr4jType(param_hydro, frac) for i in 1:nens];

  # Allocate arrays

  q_res  = zeros(Float64, ntimes, 3);
  q_sim  = zeros(Float64, 1, nens);
  swe    = zeros(Float64, nzones, nens);
  st     = zeros(Float64, 2, nens);
  st_uh1 = zeros(Float64, 20, nens);
  st_uh2 = zeros(Float64, 40, nens);

  # Start time Loop

  for itime = 1:ntimes

    # Perturb inputs and run models

    for iens = 1:nens

      perturb_input(st_snow[iens], prec, tair, itime);

      snow_model(st_snow[iens]);

      get_input(st_snow[iens], st_hydro[iens], epot, itime);

      q_sim[iens] = hydro_model(st_hydro[iens]);

    end

    # Run filter part

    if q_obs[itime] >= 0

      # Add states to arrays

      for iens = 1:nens

        swe[:, iens]    = st_snow[iens].swe;
        st[:, iens]     = st_hydro[iens].st;
        st_uh1[:, iens] = st_hydro[iens].st_uh1;
        st_uh2[:, iens] = st_hydro[iens].st_uh2;

      end

      # Perturb observations

      sigma = max(0.1 * q_obs[itime], 0.1);

      obs_ens = q_obs[itime] + sigma * randn(Float64, 1, 100);

      # Run ensemble kalman filter

      swe    = enkf(swe, obs_ens, q_sim);
      st     = enkf(st, obs_ens, q_sim);
      st_uh1 = enkf(st_uh1, obs_ens, q_sim);
      st_uh2 = enkf(st_uh2, obs_ens, q_sim);
      q_sim  = enkf(q_sim, obs_ens, q_sim);

      # Check limits of states

      swe[swe .< 0] = 0.;
      st[st .< 0] = 0.;
      st_uh1[st_uh1 .< 0] = 0.;
      st_uh2[st_uh2 .< 0] = 0.;
      q_sim[q_sim .< 0] = 0.

      st[1, st[1, :] .> param_hydro[1]] = param_hydro[1];
      st[2, st[2, :] .> param_hydro[3]] = param_hydro[3];

      # Add arrays to states

      for iens = 1:nens

        st_snow[iens].swe = swe[:, iens];
        st_hydro[iens].st = st[:, iens];
        st_hydro[iens].st_uh1 = st_uh1[:, iens];
        st_hydro[iens].st_uh2 = st_uh2[:, iens];

      end

    end

    # Store results

    q_res[itime, 1] = mean(q_sim);
    q_res[itime, 2] = minimum(q_sim);
    q_res[itime, 3] = maximum(q_sim);

  end

  return(q_res);

end

################################################################################

function run_em_all(path_inputs, path_save, path_param, period, date_start, date_stop)

  # Loop over all watersheds

  dir_all = readdir(path_inputs);

  for dir_cur in dir_all

    # Load data

    date, tair, prec, q_obs, frac = load_data("$path_inputs/$dir_cur");

    # Crop data

    date, tair, prec, q_obs = crop_data(date, tair, prec, q_obs, date_start, date_stop);

    # Compute potential evapotranspiration

    epot = epot_zero(date);

    # Load parameters

    filename = dir_cur[1:end-4] * "param_snow.txt";
    param_snow = readdlm("$path_param/param_snow/$filename", '\t');
    param_snow = squeeze(param_snow,2);

    filename = dir_cur[1:end-4] * "param_hydro.txt";
    param_hydro = readdlm("$path_param/param_hydro/$filename", '\t');
    param_hydro = squeeze(param_hydro,2);

    # Run model and filter

    nens = 100;

    q_res = run_filter(prec, tair, epot, q_obs, param_snow, param_hydro, frac, nens);

    # Add results to dataframe

    x_data = collect(1:size(q_res,1));
    q_sim  = q_res[:, 1];
    q_min  = q_res[:, 2];
    q_max  = q_res[:, 3];

    q_obs = round(q_obs, 2);
    q_sim = round(q_sim, 2);
    q_min = round(q_min, 2);
    q_max = round(q_max, 2);

    df_res = DataFrame(date = Dates.format(date,"yyyy-mm-dd"), q_obs = q_obs, q_sim = q_sim, q_min = q_min, q_max = q_max);

    # Save results to txt file

    file_save = dir_cur[1:end-5];

    writetable(string(path_save, "/" * period * "_txt/", file_save, "_station.txt"), df_res, quotemark = '"', separator = '\t');

    # Plot results

    days_warmup = 3*365;

    df_res = df_res[days_warmup:end, :];

    R"""
    library(zoo, lib.loc = "C:/Users/jmg/Documents/R/win-library/3.2")
    library(hydroGOF, lib.loc = "C:/Users/jmg/Documents/R/win-library/3.2")
    library(labeling, lib.loc = "C:/Users/jmg/Documents/R/win-library/3.2")
    library(ggplot2, lib.loc = "C:/Users/jmg/Documents/R/win-library/3.2")
    """

    R"""
    df <- $df_res
    df$date <- as.Date(df$date)
    df$q_obs[df$q_obs == -999] <- NA
    kge <- round(KGE(df$q_sim, df$q_obs), digits = 2)
    nse <- round(NSE(df$q_sim, df$q_obs), digits = 2)
    """

    R"""
    plot_title <- paste('KGE = ', kge, ' NSE = ', nse, sep = '')
    path_save <- $path_save
    file_save <- $file_save
    """

    R"""
    p <- ggplot(df, aes(date))
    p <- p + geom_ribbon(aes(ymin = q_min, ymax = q_max), fill = "deepskyblue1")
    p <- p + geom_line(aes(y = q_obs), colour = "black", size = 1)
    p <- p + geom_line(aes(y = q_sim), colour = "red", size = 0.5)
    p <- p + theme_bw()
    """

    R"""
    p <- p + labs(title = plot_title)
    p <- p + labs(x = 'Date')
    p <- p + labs(y = 'Discharge')
    ggsave(file = paste(path_save,"/",$period,"_png/",file_save,"_pfilter.png", sep = ""), width = 30, height = 18, units = 'cm', dpi = 600)
    """

  end

end

################################################################################

# Run for calibration period

period = "calib";

date_start = Date(2000,09,01);
date_stop  = Date(2014,12,31);

run_em_all(path_inputs, path_save, path_param, period, date_start, date_stop);

# Run for validation period

period = "valid";

date_start = Date(1985,09,01);
date_stop  = Date(2000,08,31);

run_em_all(path_inputs, path_save, path_param, period, date_start, date_stop);
