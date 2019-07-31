function [im, otf3d, y]=GenerateData3D(obj_name, noise,level)
%{
-------------------------------------------------------------------------------
Generate data for 3D wave propagation.

Input:   noise -> type of noise
                   - 'Gaussian'  level is PSNR
                   - 'Poisson'   level is average number of photons per pixel

Outputs: im    -> ground truth (star like object)
         psf   -> psf
         y     -> blurred and noisy data

Copyright (C) 2019 Ni Chen nichen@snu.ac.kr
-------------------------------------------------------------------------------
%}
    N = 128;
    switch obj_name
        case 'random'
            im = randomScatter(N, N, 1);
        case 'conhelix'
            im = conHelix(N, N, 0.8, 8);
        case 'circhelix'
            im = circHelix(N, N, 0.4, 6);
        case 'star' % Star-like object (help StarLikeSample to see the details of parameters)
            im = randomScatter(N, N, 1);
    end

    lambda = 532e-9;                % Illumination wavelength
    pps = 3.45e-6;      % pixel pitch of CCD camera
    z0 = 100e-3;     % propagation distance
    dz = 500e-6;
    z = z0 + ((1:N)-N/2)*dz;

    %% Data
    H = LinOpWavePropKernel(lambda, N, N, pps, z);
    y_noNoise = H*im;

    if strcmp(noise,'Gaussian')
        noise = 10^(-level/20).*random('Normal',zeros(size(y_noNoise)),ones(size(y_noNoise))) + ...
            1i* 10^(-level/20).*random('Normal',zeros(size(y_noNoise)),ones(size(y_noNoise)))  ;
        
        y = y_noNoise + noise;
        y = y./max(abs(y(:)));
        
    elseif strcmp(noise,'Poisson')
        factor = level./mean(y_noNoise(:)) ;
        y_noNoise = y_noNoise.* factor;
        im = im.*factor;
        y = random('Poisson', y_noNoise);
        y = y./max(abs(y(:)));
    else
        error('Wrong type of noise');
    end
    otf3d = H.mtf;
end