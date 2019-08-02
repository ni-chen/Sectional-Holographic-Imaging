%--------------------------------------------------------------
% This script performs 3D deconvolution using CP with
%    - Data-term: Least-Squares or Kullback-Leibler
%    - regul: TV or Hessian-Schatten norm
%--------------------------------------------------------------

close all; clear; clc;

addpath(genpath('./function/'));
% reset(gpuDevice(1));

%% ----------------------------------------- Parameters --------------------------------------------
obj_name = 'circhelix';  %'random', 'conhelix', 'circhelix', 'star'

isGPU = 0;
isNonNeg = 0;
cost_type = 'LS';  % LS, KL
reg_type = '3DTV';   % TV:, HS:Hessian-Shatten
solv_type = 'ADMM';  % CP, ADMM, CG, RL, FISTA, VMLMB

maxit = 20;       % Max iterations

% file_name = [obj_name, '_', cost_type, '+', reg_type, '(Neg ', num2str(isNonNeg), ')+', solv_type];
if isNonNeg
    file_name = [obj_name, '_', cost_type, '+', reg_type, '(Neg ', num2str(isNonNeg), ')+', solv_type];
else
    file_name = [obj_name, '_', cost_type, '+', reg_type, '+', solv_type];
end
%% fix the random seed (for reproductibility)
rng(1);
useGPU(isGPU);

%% -------------------------------------- Image generation -----------------------------------------
[im, otf, y] = setHoloData(obj_name, 'Gaussian', 50);
if isGPU; otf = gpuCpuConverter(otf); im = gpuCpuConverter(im); y = gpuCpuConverter(y); end
% Orthoviews(im,[],'Input Image (GT)');
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
        KL = CostKullLeib([],y,1e-6);     % Kullback-Leibler divergence data term
        F = KL*H;
        
        F.doPrecomputation = 1;
        C = LinOpCpx(sz);
end

%% ----------------------------------------- regularizer -------------------------------------------
switch reg_type
    case 'TV'  % TV regularizer
        G = LinOpGrad(C.sizeout,[1,2]);       % Operator Gradient
        R_N12 = CostMixNorm21(G.sizeout,4);   % Mixed Norm 2-1
        
        R_POS = CostNonNeg(sz);           % Non-Negativity
        Id = LinOpIdentity(sz);
    case '3DTV'  % 3D TV regularizer
        G = LinOpGrad(C.sizeout, [1,2,3]);    % TV regularizer: Operator gradient
        R_N12 = CostMixNorm21(G.sizeout,4);   % TV regularizer: Mixed norm 2-1, check
        
        R_POS = CostNonNeg(sz);           % Non-Negativity
        Id = LinOpIdentity(sz);               % Identity Operator
        
    case 'HS'  % Hessian-Shatten
        G = LinOpHess(C.sizeout);                 % Hessian Operator
        R_N12 = CostMixNormSchatt1([sz, 3],1); % Mixed Norm 1-Schatten (p = 1)
        
        R_POS = CostNonNeg(sz);           % Non-Negativity
        Id = LinOpIdentity(sz);
end

%% ---------------------------------------- Optimization --------------------------------------------

switch solv_type   
    case 'CP'
        % ------------------------------- Chambolle-Pock  LS + TV ---------------------------------
        lamb = 1e-3;  % circhelix: 1e-3

        optSolve = OptiChambPock(lamb*R_N12,G*C,F);
        optSolve.tau = 1;  % 1, algorithm parameters, 15
        optSolve.sig = 1/(optSolve.tau*G.norm^2)*0.99;  % sig x tau x ?H?2 <= 1
%         optSolve.gam = 1;  % 1 or 2
%         optSolve.var = 1;  % 1: ; 2:
        
        file_name = [file_name, '(', num2str(optSolve.tau) ,')'];
    case 'ADMM'
        %% ----------------------------------- ADMM LS + TV ----------------------------------------
        lamb = 1e-3; % Hyperparameter, lamb = 1e-2;
        file_name = [file_name, '(', num2str(lamb) ,')'];
        
        if ~isNonNeg % ADMM LS + TV 
            Fn = {lamb*R_N12}; % Functionals F_n constituting the cost
            Hn = {G*C}; % Associated operators H_n
            rho_n = [1e-1]; % Multipliers rho_n, [1e-1];
            
        else  % ADMM LS + TV + NonNeg 
            Fn = {lamb*R_N12, R_POS}; % Functionals F_n constituting the cost
            Hn = {G*C, Id}; % Associated operators H_n
            rho_n = [1e-2, 1e-2]; % Multipliers rho_n
            file_name = [file_name, '(', num2str(rho_n(1)) ,')'];
        end

        % Here no solver needed in ADMM since the operator H'*H + alpha*G'*G is invertible
        optSolve = OptiADMM(F,Fn,Hn,rho_n); % Declare optimizer
        
    case 'FISTA' % Forward-Backward Splitting optimization  
        lamb = 1e-3;  % circhelix: 1e-3
        optSolve = OptiFBS(F,R_POS);
%         optSolve = OptiFBS(F, lamb*R_N12);
        optSolve.fista = true;   % true if the accelerated version FISTA is used
        optSolve.gam = 5;     % descent step
        optSolve.momRestart  = false; % true if the moment restart strategy is used
        
    case 'RL' % Richardson-Lucy algorithm
        lamb = 1e-2; % Hyperparameter for TV
        optSolve = OptiRichLucy(F, 1, lamb);
        optSolve.epsl = 1e-6; % smoothing parameter to make TV differentiable at 0 
        
    case 'PD' % PrimalDual Condat KL
        lamb = 1e-3;                  % Hyperparameter
%         if ~isNonNeg
%             Fn = {lamb*R_N12, KL};
%             Hn = {Hess,H};
%             optSolve = OptiPrimalDualCondat([],R_POS,Fn,Hn);
%         else  % PD + LS + TV + NonNeg
            Fn = {lamb*R_N12};
            Hn = {G*C};
            optSolve = OptiPrimalDualCondat(F,R_POS,Fn,Hn);
%         end
        optSolve.OutOp = OutputOptiSNR(1, im, round(maxit/10), [2 3]);
        optSolve.tau = 1;          % set algorithm parameters
        optSolve.sig = (1/optSolve.tau-F.lip/2)/G.norm^2*0.9;    %
        optSolve.rho = 1.95;          %
        
    case 'VMLMB' % optSolve LS 
        lamb = 1e-3;                  % Hyperparameter
        if ~isNonNeg
            hyperB = CostHyperBolic(G.sizeout, 1e-7, 3)*G*C;
            C1 = F + lamb*hyperB; 
            C1.memoizeOpts.apply=true;
            optSolve = OptiVMLMB(C,0,[]);
            optSolve.m = 3;  % number of memorized step in hessian approximation (one step is enough for quadratic function)
        else
            hyperB = CostHyperBolic(G.sizeout, 1e-7, 3)*G;
            C1 = F + lamb*hyperB; 
            C1.memoizeOpts.apply=true;
            optSolve = OptiVMLMB(C1,0.,[]);  
            optSolve.m = 3; 
        end        
        
    case 'CG'  % ConjGrad LS 
        A = H.makeHtH();
        b = H'*y;
        optSolve = OptiConjGrad(A,b);  
        optSolve.OutOp = OutputOptiConjGrad(1,dot(y(:),y(:)),im,40);  
        
    case 'FCG'  % ConjGrad LS 
        optSolve = OptiFGP(A,b);  
end
optSolve.maxiter = maxit;                             % max number of iterations
optSolve.OutOp = OutputOptiSNR(1,im,round(maxit/10));
optSolve.ItUpOut = round(maxit/10);         % call OutputOpti update every ItUpOut iterations
optSolve.CvOp = TestCvgCombine(TestCvgCostRelative(1e-10), 'StepRelative', 1e-10);
optSolve.run(zeros(size(otf)));             % run the algorithm

save(['./output/', file_name, '.mat'], 'optSolve');

%% -------------------------------------------- Display --------------------------------------------
% Orthoviews(im,[],'Input Image (GT)');
% figure; show3d(gather(im), 0.001); axis normal;
% imdisp(abs(y),'Convolved mag', 1); imdisp(angle(y),'Convolved phase', 1);
% 
% % Back-propagation reconstruction
% im_bp = LinOpAdjoint(H)*y;
% Orthoviews(abs(im_bp),[],'BP Image');

% Deconvolution reconstruction comparison
solve_lst = dir(['./output/', obj_name, '_*.mat']);
img_num = length(solve_lst);

if img_num > 0    
%     reset(gpuDevice(1));
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
    grid;title('Cost evolution'); set(gca,'FontSize',12);xlabel('Iterations');ylabel('Cost');
    for imidx = 1:img_num 
        plot(solve_result{imidx}.OutOp.iternum,solve_result{imidx}.OutOp.evolcost,'LineWidth',1.5);     
        hold all;
    end
    legend(legend_name); 
    set(gcf,'paperpositionmode','auto');
    print('-dpng', ['./output/', obj_name, '_cost.png']);
    
    % Show SNR
    figure('Name', 'SNR');    
    grid; hold all; title('Evolution SNR');set(gca,'FontSize',10);
    for imidx = 1:img_num
        semilogy(solve_result{imidx}.OutOp.iternum,solve_result{imidx}.OutOp.evolsnr,'LineWidth',1.5);
    end
    legend(legend_name,'Location','southeast');
    xlabel('Iterations');ylabel('SNR (dB)');
    set(gcf,'paperpositionmode','auto');
    print('-dpng', ['./output/', obj_name, '_snr.png']);
    
%     figure('Name', 'Time cost');    
%     hold on; grid; title('Runing Time');set(gca,'FontSize',12);
%     orderCol = get(gca,'ColorOrder');
%     for imidx = 1:img_num   
%         bar(imidx,[solve_result{imidx}.time],'FaceColor',orderCol(imidx,:),'EdgeColor','k');
%     end
%     set(gca,'xtick',1:img_num);ylabel('Time (s)'); set(gca,'xticklabels', legend_name);
%     set(gca,'XTickLabelRotation',50);
%     set(gcf,'paperpositionmode','auto');
%     print('-dpng', ['./output/', obj_name, '_time.png']);
end

