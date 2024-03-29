function holoout = holodenoise(holoin, gr)
   
    if ~(isreal(holoin))

        sigma = evar(real(holoin));
        sigma = sqrt(sigma);
        sigma = 1;
        gausFilter = fspecial('gaussian', [gr,gr], sigma);
        holo_re = imfilter(real(holoin), gausFilter, 'replicate');

        sigma = evar(imag(holoin));
        sigma = sqrt(sigma);
        sigma = 1;
        gausFilter = fspecial('gaussian', [gr,gr], sigma);
        holo_im = imfilter(imag(holoin), gausFilter, 'replicate');

        holoout = holo_re + 1i*holo_im;
    else
        sigma = evar(holoin);
        gausFilter = fspecial('gaussian', [gr,gr], sigma);
        holoout = imfilter(holoin, gausFilter, 'replicate');
    end
end
