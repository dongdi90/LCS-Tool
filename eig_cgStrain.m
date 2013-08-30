% eig_cgStrain Calculate eigenvalues and eigenvectors of Cauchy-Green strain
%
% SYNTAX
% [cgStrainD,cgStrainV,cgStrain,finalPosition,dFlowMap] = eig_cgStrain(flow,method,customEigMethod,coupledIntegration,verbose)
%
% DESCRIPTION
% method.name should be either 'finiteDifference' or 'equationOfVariation'
% If method.name is 'finiteDifference', method.auxiliaryGridRelativeDelta
% can be specified. It should be a number between 0 and 0.5. If method.name
% is 'finiteDifference', method.eigenvalueFromMainGrid can be set to true
% or false to control whether eigenvalues of the Cauchy-Green strain are
% calculated from main grid or auxiliary grid points.
%
% customEigMethod should be true or false.
%
% coupledIntegration should be true or false.
%
% verbose.progress and verbose.stats should be true or false.

function [cgStrainD,cgStrainV,cgStrain,finalPosition,dFlowMap] = eig_cgStrain(flow,varargin)

%% Parse inputs
narginchk(1,5)

p = inputParser;
p.StructExpand = false;
addRequired(p,'flow',@isstruct)
addOptional(p,'method',struct('name','equationOfVariation'),@isstruct)
addOptional(p,'customEigMethod',false,@islogical)
addOptional(p,'coupledIntegration',true,@islogical)
addOptional(p,'verbose',struct('progress',false,'stats',false),@isstruct)

parse(p,flow,varargin{:})

method = p.Results.method;
customEigMethod = p.Results.customEigMethod;
coupledIntegration = p.Results.coupledIntegration;
verbose = p.Results.verbose;

p = inputParser;
p.KeepUnmatched = true;

addParamValue(p,'odeSolverOptions',[],@isstruct);
parse(p,flow)

odeSolverOptions = p.Results.odeSolverOptions;

%% Main code
initialPosition = initialize_ic_grid(flow.resolution,flow.domain);

switch method.name
    case 'finiteDifference'
        
        %% Parse method structure
        p = inputParser;
        p.KeepUnmatched = true;
        validationFcn = @(x) isnumeric(x) && isscalar(x) && (x > 0) && (x <= .5);
        addParamValue(p,'auxiliaryGridRelativeDelta',1e-2,validationFcn)
        addParamValue(p,'eigenvalueFromMainGrid',true,@islogical)
        parse(p,method)
        
        auxiliaryGridRelativeDelta = p.Results.auxiliaryGridRelativeDelta;
        eigenvalueFromMainGrid = p.Results.eigenvalueFromMainGrid;
        
        %% Eigenvectors from auxiliary grid
        deltaX = (flow.domain(1,2) - flow.domain(1,1))/double(flow.resolution(1))*auxiliaryGridRelativeDelta;
        auxiliaryGridAbsoluteDelta = deltaX;
        auxiliaryPosition = auxiliary_position(initialPosition,auxiliaryGridAbsoluteDelta);
        
        % Transform auxiliaryPosition into a two column array
        auxiliaryPositionX = auxiliaryPosition(:,1:2:end-1);
        auxiliaryPositionY = auxiliaryPosition(:,2:2:end);
        auxiliaryPosition = [auxiliaryPositionX(:) auxiliaryPositionY(:)];
        
        if coupledIntegration
            finalPositionAuxGrid = ode45_vector(@(t,y)flow.derivative(t,y,false),flow.timespan,auxiliaryPosition,false,odeSolverOptions);
        else
            error('Uncoupled integration code not programmed')
        end
        
        % Transform finalPosition into an eight column array
        finalPositionAuxGridX = finalPositionAuxGrid(:,1);
        finalPositionAuxGridY = finalPositionAuxGrid(:,2);
        nPoints = prod(double(flow.resolution));
        finalPositionAuxGridX = reshape(finalPositionAuxGridX,nPoints,4);
        finalPositionAuxGridY = reshape(finalPositionAuxGridY,nPoints,4);
        finalPositionAuxGrid = nan(nPoints,8);
        finalPositionAuxGrid(:,1:2:7) = finalPositionAuxGridX;
        finalPositionAuxGrid(:,2:2:8) = finalPositionAuxGridY;
        
        cgStrainAuxGrid = compute_cgStrain(finalPositionAuxGrid,flow,auxiliaryGridRelativeDelta);
        
        [cgStrainV,cgStrainD] = arrayfun(@(x11,x12,x22)eig_array(x11,x12,x22,customEigMethod),cgStrainAuxGrid(:,1),cgStrainAuxGrid(:,2),cgStrainAuxGrid(:,3),'UniformOutput',false);
        
        cgStrainV = cell2mat(cgStrainV);
        
        %% Eigenvalues from main grid
        if eigenvalueFromMainGrid
            initialPosition = initialize_ic_grid(flow.resolution,flow.domain);
          
            if coupledIntegration
                finalPositionMainGrid = ode45_vector(@(t,y)flow.derivative(t,y,false),flow.timespan,initialPosition,false,odeSolverOptions);
            else
                error('Uncoupled integration code not programmed')
            end
            
            cgStrainMainGrid = compute_cgStrain(finalPositionMainGrid,flow);
            
            [~,cgStrainD] = arrayfun(@eig_array,cgStrainMainGrid(:,1),cgStrainMainGrid(:,2),cgStrainMainGrid(:,3),'UniformOutput',false);
        end
        
        cgStrainD = cell2mat(cgStrainD);
        
        % Use the Cauchy-Green strain calculated with the auxiliary
        % grid for statistics.
        nRows = size(cgStrainAuxGrid,1);
        cgStrain = arrayfun(@(idx)[cgStrainAuxGrid(idx,1),cgStrainAuxGrid(idx,2);cgStrainAuxGrid(idx,2),cgStrainAuxGrid(idx,3)],1:nRows,'uniformOutput',false);
        cgStrain = cell2mat(cgStrain);
        cgStrain = reshape(cgStrain,[2 2 nRows]);
        
    case 'equationOfVariation'
        
        dFlowMap0 = eye(2);
        dFlowMap0 = reshape(dFlowMap0,4,1);
        nPosition = size(initialPosition,1);
        finalPosition = nan(nPosition,2);
        dFlowMap = nan(nPosition,4);
        
        if coupledIntegration
            initialPosition = [initialPosition,repmat(transpose(dFlowMap0),size(initialPosition,1),1)];
            sol = ode45_vector(@(t,y)flow.derivative(t,y,true),flow.timespan,initialPosition,true,odeSolverOptions);
            dFlowMap = sol(:,3:6);
            % FIXME Check indices in flow definition file.
            dFlowMap(:,[2,3]) = fliplr(dFlowMap(:,[2,3]));
            finalPosition = sol(:,1:2);
        else
            parfor iPosition = 1:nPosition
                position0 = transpose(initialPosition(iPosition,:));
                y0 = [position0;dFlowMap0];
                sol = ode45(@(t,y)flow.derivative(t,y,true),flow.timespan,y0,odeSolverOptions); %#ok<PFBNS>
                finalPosition(iPosition,:) = transpose(deval(sol,flow.timespan(end),1:2));
                dFlowMap(iPosition,:) = transpose(deval(sol,flow.timespan(end),3:6));
            end
        end
        
        cgStrain = cgStrain_from_dFlowMap(dFlowMap);
        [cgStrainV,cgStrainD] = arrayfun(@(a1,a2,a4)eig_array(a1,a2,a4),squeeze(cgStrain(1,1,:)),squeeze(cgStrain(1,2,:)),squeeze(cgStrain(2,2,:)),'UniformOutput',false);
        cgStrainV = cell2mat(cgStrainV);
        cgStrainD = cell2mat(cgStrainD);
end

if isfield(flow,'imposeIncompressibility') && flow.imposeIncompressibility == true
    idx = cgStrainD(:,2) < 1;
    n = sum(idx);
    if n
        if n > 1
            warning([mfilename,':imposeIncompressibility'],['Larger eigenvalue less than one at ',num2str(n),' points. Incompressibility not imposed at those points.'])
        else
            warning([mfilename,':imposeIncompressibility'],['Larger eigenvalue less than one at ',num2str(n),' point. Incompressibility not imposed at that point.'])
        end
    end    
    cgStrainD(~idx,1) = 1./cgStrainD(~idx,2);
end

[cgStrainD,cgStrainV,cgStrain] = negative_to_nan(cgStrainD,cgStrainV,cgStrain);

if verbose.stats
    disp('cgStrain_stats:')
    cgStrain_stats(cgStrain,cgStrainV,cgStrainD)
end

% eig_array eig function for use with arrayfun
%
% SYNTAX
% [v,d] = eig_array(x11,x12,x22)
% [v,d] = eig_array(x11,x12,x22,customMethod)

function [v,d] = eig_array(x11,x12,x22,varargin)

narginchk(3,4)

p = inputParser;
addOptional(p,'customMethod',false,@islogical)
parse(p,varargin{:})
customMethod = p.Results.customMethod;

if customMethod
    [v,d] = eig_custom([x11,x12;x12,x22]);
else    
    [v,d] = eig([x11,x12;x12,x22]);
end

d = transpose(diag(d));
v = reshape(v,1,4);

function cgStrain = cgStrain_from_dFlowMap(dFlowMap)

nRows = size(dFlowMap,1);
dFlowMap = reshape(transpose(dFlowMap),[2 2 nRows]);
cgStrain = arrayfun(@(idx)transpose(dFlowMap(:,:,idx))*dFlowMap(:,:,idx),1:nRows,'UniformOutput',false);
cgStrain = cell2mat(cgStrain);
cgStrain = reshape(cgStrain,[2 2 nRows]);

function [v,d] = eig_custom(a)

d(2,2) = .5*trace(a) + sqrt(.25*trace(a)^2 - det(a));
d(1,1) = .5*trace(a) - sqrt(.25*trace(a)^2 - det(a));
if any(imag(d(:)))
    warning([mfilename,':complexEigenvalue'],['Complex eigenvalue: ',num2str(d([1,4]))])
end

v(1,2) = -a(1,2)/sqrt(a(1,2)^2 + (a(1,1) - d(2,2))^2);
v(2,2) = (a(1,1) - d(2,2))/sqrt(a(1,2)^2 + (a(1,1) - d(2,2))^2);

v(1,1) = v(2,2);
v(2,1) = -v(1,2);

function yf = ode45_vector(odefun,tspan,y0,useEoV,options)

% Reshape m-by-2 array to column array
y0 = transpose(y0);
y0 = y0(:);

if useEoV
    coupledSize = 6;
else
    coupledSize = 2;
end

sol = ode45(odefun,tspan,y0,options);
yf = deval(sol,tspan(end));
yf = transpose(reshape(yf,coupledSize,size(yf,1)/coupledSize));

% Set points with negative eigenvalues to NaN
% The Cauchy-Green strain tensor is positive definite, but numerical
% integration does not enforce this. This function sets those points where
% the Cauchy-Green strain tensor is not positive definite to NaN
function [cgStrainD,cgStrainV,cgStrain] = negative_to_nan(cgStrainD,cgStrainV,cgStrain)

negIdx = any(cgStrainD <= 0,2);

cgStrainD(negIdx,:) = nan;
cgStrainV(negIdx,:) = nan;
cgStrain(:,:,negIdx) = nan;

function auxiliaryPosition = auxiliary_position(basePosition,delta)
%AUXILIARY_POSITION Auxiliary grid positions
%   auxiliaryPosition = AUXILIARY_POSITION(position,delta)
%
%   BASE_POSITION gives coordinates in rows. For 2 dimensional problems
%   it must have two columns and one row for each coordinate. For 3
%   dimensional problems it must have three columns.
%
%   AUXILIARY_POSITION_ has the same format as INITIAL_POSITION, but each
%   row gives positions at auxiliary positions. In 2 dimensions, each
%   row has 8 columns with the format:
%      X+DELTA Y X-DELTA Y X Y+DELTA X Y-DELTA

if size(basePosition,2) == 2
    nColAuxiliaryPosition = 8;
elseif size(basePosition,2) == 3
    nColAuxiliaryPosition = 12;
else
    error('Auxiliary position:Column Number Error')
end

auxiliaryPosition = nan(size(basePosition,1),nColAuxiliaryPosition);

auxiliaryPosition(:,1) = basePosition(:,1) + delta;
auxiliaryPosition(:,2) = basePosition(:,2);
auxiliaryPosition(:,3) = basePosition(:,1) - delta;
auxiliaryPosition(:,4) = basePosition(:,2);
auxiliaryPosition(:,5) = basePosition(:,1);
auxiliaryPosition(:,6) = basePosition(:,2) + delta;
auxiliaryPosition(:,7) = basePosition(:,1);
auxiliaryPosition(:,8) = basePosition(:,2) - delta;
