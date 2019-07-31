%--------------------------------------------------------------
% This script performs 3D deconvolution using CP with
%    - Data-term: Least-Squares or Kullback-Leibler
%    - regul: TV or Hessian-Schatten norm
%--------------------------------------------------------------

close all; clear; clc;
addpath(genpath('./function/'));

%% ----------------------------------------- Parameters --------------------------------------------
obj_name = 'circhelix';  %'random', 'conhelix', 'circhelix', 'star'

isGPU = 1;
cost_type = 'LS';
reg_type = 'TV';     % TV:, HS:Hessian-Shatten
solv_type = 'ADMM';  % CP, ADMM, CG, RL

maxit = 100;       % Max iterations

file_name = [obj_name, '_', cost_type, '+', reg_type, '+', solv_type];

%% fix the random seed (for reproductibility)
rng(1);
useGPU(isGPU);

%% -------------------------------------- Image generation -----------------------------------------
[im, otf, y] = GenerateData3D(obj_name, 'Gaussian', 50);
if isGPU; otf = gpuCpuConverter(otf); im = gpuCpuConverter(im); y = gpuCpuConverter(y); end

%% ----------------------------------------- Foward Model ------------------------------------------
sz = size(otf);
H1 = LinOpConv(otf, 0, [1 2]); 
S = LinOpSum(sz,3);
H = S*H1;   

%% --------------------------------------------- Cost ----------------------------------------------
switch cost_type
    case 'LS'   % Least-Squares
        LS = CostL2([],y);
        F = LS*H;
        
        F.doPrecomputation = 1;
        C = LinOpCpx(sz);
    case 'KL'  % Kullback-Leibler divergence 
end

%% ----------------------------------------- regularizer -------------------------------------------
switch reg_type
    case 'TV'  % TV regularizer
        G = LinOpGrad(C.sizeout,[1,2]);      % Operator Gradient
        R_N12 = CostMixNorm21(G.sizeout,4);  % Mixed Norm 2-1
        
    case '3DTV'  % 3D TV regularizer
%         G = LinOpGrad(C.sizeout,[1,2]);      % Operator Gradient
%         R_N12 = CostMixNorm21(G.sizeout,4);  % Mixed Norm 2-1
        R_N12 = CostMixNorm21([sznew,3],4);      % TV regularizer: Mixed norm 2-1
        G = LinOpGrad(sznew);               % TV regularizer: Operator gradient
        
    case 'HS'  % Hessian-Shatten
        Freg = CostMixNormSchatt1([sz,6],1); % Mixed Norm 1-Schatten (p = 1)
        Opreg = LinOpHess(sz);               % Hessian Operator
end

KL = CostKullLeib([],y,1e-6);     % Kullback-Leibler divergence data term
R_POS = CostNonNeg(sz);           % Non-Negativity

%% ---------------------------------------- Optimization --------------------------------------------

switch solv_type   
    case 'CP'
        % ------------------------------- Chambolle-Pock  LS + TV ---------------------------------
        lamb = 1e-3;  % Hyperparameter
        
        optSolve = OptiChambPock(lamb*R_N12,G*C,F);
        optSolve.CvOp = TestCvgCombine(TestCvgCostRelative(1e-5), 'StepRelative', 1e-5);
        optSolve.tau = 1;  % algorithm parameters
        % CP.sig = 0.2;
        optSolve.sig = 1/(optSolve.tau*G.norm^2)*0.99; %
        
    case 'ADMM'
        %% ----------------------------------- ADMM LS + TV ----------------------------------------
        lamb = 1e-2; % Hyperparameter
        
        Fn = {lamb*R_N12}; % Functionals F_n constituting the cost
        Hn = {G*C}; % Associated operators H_n
        rho_n = [1e+1]; % Multipliers rho_n

        % Fn = {lamb*R_N12, R_POS}; % Functionals F_n constituting the cost
        % Hn = {G*C, Id*C}; % Associated operators H_n
        % rho_n = [1e+1, 1e+1]; % Multipliers rho_n

        % Here no solver needed in ADMM since the operator H'*H + alpha*G'*G is invertible
        optSolve = OptiADMM(F,Fn,Hn,rho_n); % Declare optimizer
        optSolve.CvOp = TestCvgCombine(TestCvgCostRelative(1e-5), 'StepRelative', 1e-5);
        
    case 'FISTA' % Forward-Backward Splitting optimization algorithm 
        optSolve = OptiFBS(KL*H,R_POS);
        optSolve.fista = true;   % activate fista
        optSolve.gam = 5;     % set gamma parameter

        
    case 'RL' % Richardson-Lucy algorithm
        optSolve = OptiRichLucy(KL*H);
        
    case 'PD' % PrimalDual Condat KL
        lamb = 1e-2;                  % Hyperparameter
        
        Fn = {lamb*R_1sch,KL};
        Hn = {Hess,H};
        optSolve = OptiPrimalDualCondat([],R_POS,Fn,Hn);
        optSolve.OutOp = OutputOptiSNR(1, im, round(maxit/10), [2 3]);
        optSolve.tau = 100;          % set algorithm parameters
        optSolve.sig = 1e-2;            %
        optSolve.rho = 1.2;          %
        
    case 'VMLMB' % optSolve LS 
        optSolve = OptiVMLMB(F,[],[]);  
        optSolve.m = 2;                                     % number of memorized step in hessian approximation (one step is enough for quadratic function)
        
    case 'CG'  % ConjGrad LS 
        A = H.makeHtH();
        b = H'*y;
        optSolve = OptiConjGrad(A,b);  
        optSolve.OutOp = OutputOptiConjGrad(1,dot(y(:),y(:)),im,40);                                 
end
optSolve.maxiter = maxit;                             % max number of iterations
optSolve.OutOp = OutputOptiSNR(1,im,round(maxit/10));
optSolve.ItUpOut = round(maxit/10);         % call OutputOpti update every ItUpOut iterations
optSolve.run(zeros(size(otf)));             % run the algorithm

save(['./output/', file_name, '.mat'], 'optSolve');

%% -------------------------------------------- Display --------------------------------------------
Orthoviews(im,[],'Input Image (GT)');
figure; show3d(gather(im), 0.001); axis normal;
imdisp(abs(y),'Convolved mag', 1); imdisp(angle(y),'Convolved phase', 1);

% Back-propagation reconstruction
im_bp = LinOpAdjoint(H)*y;
Orthoviews(abs(im_bp),[],'BP Image');

% Deconvolution reconstruction comparison
solve_lst = dir(['./output/', obj_name, '_*.mat']);
img_num = length(solve_lst);

if img_num > 0    
    legend_name = {};
    method_name = {};
    
    for imidx = 1:img_num 
        solve_name = solve_lst(imidx).name;
        load(['./output/', solve_name]);
        solve_result{imidx} = optSolve;
        
        temp = strrep(solve_name, [obj_name, '_'], '');
        method_name{imidx} = strrep(temp, '.mat', '');
        
        legend_name = [legend_name, method_name{imidx}];
        
%         temp = abs(gather(optSolve.xopt));  %temp = abs(gather(optSolve.xopt));
%         Orthoviews(temp,[], method_name{imidx});
%         temp = (temp-min(temp(:)))/(max(temp(:))-min(temp(:))); 
%         figure('Name', method_name{imidx}); show3d(temp, 0.05); axis normal;
    end
          
    figure('Name', 'Cost evolution'); 
    grid; set(gca,'FontSize',12);xlabel('Iterations');ylabel('Cost');
    for imidx = 1:img_num 
        plot(solve_result{imidx}.OutOp.iternum,solve_result{imidx}.OutOp.evolcost,'LineWidth',1.5);     
        hold all;
    end
    legend(legend_name); 
    
    % Show SNR
    figure('Name', 'SNR + time');    
    subplot(1,2,1); grid; hold all; title('Evolution SNR');set(gca,'FontSize',12);
    for imidx = 1:img_num   
        semilogy(solve_result{imidx}.OutOp.iternum,solve_result{imidx}.OutOp.evolsnr,'LineWidth',1.5);
    end
    legend(legend_name,'Location','southeast');
    xlabel('Iterations');ylabel('SNR (dB)');
    subplot(1,2,2);hold on; grid; title('Runing Time');set(gca,'FontSize',12);
    orderCol = get(gca,'ColorOrder');
    for imidx = 1:img_num   
        bar(imidx,[solve_result{imidx}.time],'FaceColor',orderCol(imidx,:),'EdgeColor','k');
    end
    set(gca,'xtick',[1 2]);ylabel('Time (s)'); set(gca,'xticklabels',legend_name);
    set(gca,'XTickLabelRotation',45);
end
