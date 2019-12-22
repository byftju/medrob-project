% testing mode 1 (NOT WORKING ATM)

%%
%   INIT STUFF
%%
cd(fileparts(mfilename('fullpath')));
clear;
close all;
clc;

pause(3);
%%
% CONNECTION TO VREP
%%

[ID,vrep] = init_connection();

%%
% COLLECTING HANDLES
%%

% vision sensor
[~, h_VS]=vrep.simxGetObjectHandle(ID, 'Vision_sensor_ECM', vrep.simx_opmode_blocking);

% force sensor
[~, h_FS]=vrep.simxGetObjectHandle(ID, 'Force_sensor', vrep.simx_opmode_blocking);

% reference for direct kin
% first RRP joints
[~, h_j1] = vrep.simxGetObjectHandle(ID,'J1_PSM1',vrep.simx_opmode_blocking);
[~, h_j2] = vrep.simxGetObjectHandle(ID,'J2_PSM1',vrep.simx_opmode_blocking);
[~, h_j3] = vrep.simxGetObjectHandle(ID,'J3_PSM1',vrep.simx_opmode_blocking);

% second RRR joints
[~, h_j4] = vrep.simxGetObjectHandle(ID,'J1_TOOL1',vrep.simx_opmode_blocking);
[~, h_j5] = vrep.simxGetObjectHandle(ID,'J2_TOOL1',vrep.simx_opmode_blocking);
[~, h_j6] = vrep.simxGetObjectHandle(ID,'J3_TOOL1',vrep.simx_opmode_blocking);

% grippers (not used atm)
[~, h_7sx] = vrep.simxGetObjectHandle(ID,'J3_sx_TOOL1',vrep.simx_opmode_blocking);
[~, h_7dx] = vrep.simxGetObjectHandle(ID,'J3_dx_TOOL1',vrep.simx_opmode_blocking);

% reference for direct kin
[~, h_RCM]=vrep.simxGetObjectHandle(ID, 'RCM_PSM1', vrep.simx_opmode_blocking);
relativeToObjectHandle = h_RCM; % relative to which frame you want to know position of ee

[sync] = syncronize( ID , vrep, h_j1, h_j2, h_j3, h_j4, h_j5, h_j6, h_7sx, h_7dx, h_RCM);
if sync
    fprintf(1,'Sycronization: OK... \n');
    pause(1);
end

% preallocating for speed
h_L = zeros(4,5); % here i save handles of landmarks
h_L_EE = zeros(4,5); % here i save handles of balls attacched to EE

% landmarks attached to goal positions :
% we have 5 location to achieve
% each location has 4 landmarks

for b=1:4 % each spot has 4 balls
    for s=1:5 % 5 total spots
        [~, h_L(b,s)]=vrep.simxGetObjectHandle(ID, ['Landmark', num2str(s), num2str(b)], vrep.simx_opmode_blocking);
    end
end

% landmarks attached to EE -> 'LandmarkEE1,2,3,4'
for b=1:4
    [~, h_L_EE(b)]=vrep.simxGetObjectHandle(ID, ['LandmarkEE', num2str(b)], vrep.simx_opmode_blocking);
end

%%
%   SETTINGS
%%

% focal length (depth of the near clipping plane)
fl = 0.01;

% control gain in mode 0 (see below)
K = eye(6)*(10^-2);

% control gain in mode 1 (see below)
H = eye(6)*(10^-1);

% compliance matrix of manipulator
C = eye(6)*(10^-1);

% preallocating for speed
us_desired = zeros(4,5);
vs_desired = zeros(4,5);
sync=false;

% desired features EXTRACTION
for b=1:4 % balls
    for s=1:5 % spots
        while ~sync % until i dont get valid values
            [~, l_position]=vrep.simxGetObjectPosition(ID, h_L(b,s), h_VS, vrep.simx_opmode_streaming);
            sync = norm(l_position,2)~=0;
        end
        sync=false;
        
        % here you have all landmark positions in image plane
        us_desired(b,s)= fl*l_position(1)/l_position(3);
        vs_desired(b,s)= fl*l_position(2)/l_position(3);
        
    end
end

% null desired force and torque
force_torque_d=zeros(6,1);

% PROCESS LOOP
mode = 1;
time = 0;
% start from landmark at spot+1
spot = 1;

% loop
disp("------- STARTING -------");

while spot<6
    
    time = time +1;
    
    % getting current values of joints
    [~, q1]=vrep.simxGetJointPosition(ID,h_j1,vrep.simx_opmode_buffer);
    [~, q2]=vrep.simxGetJointPosition(ID,h_j2,vrep.simx_opmode_buffer);
    [~, q3]=vrep.simxGetJointPosition(ID,h_j3,vrep.simx_opmode_buffer);
    [~, q4]=vrep.simxGetJointPosition(ID,h_j4,vrep.simx_opmode_buffer);
    [~, q5]=vrep.simxGetJointPosition(ID,h_j5,vrep.simx_opmode_buffer);
    [~, q6]=vrep.simxGetJointPosition(ID,h_j6,vrep.simx_opmode_buffer);
    Q = [q1,q2,q3,q4,q5,q6];
    pause(0.2);
    
    if mode==1
        
        % _________________________________________________________________
        % _________________________________________________________________
        
        % 1) FEATURE EXTRACTION OF EE
        
        us_current = zeros(4,1);
        vs_currect = zeros(4,1);
        zs_current = zeros(4,1);
        
        % GETTING CURRECT POSITION OF EE IN IMAGE PLANE
        for b=1:4 % balls
            while ~sync  % until i dont get valid values
                [~, l_position]=vrep.simxGetObjectPosition(ID, h_L_EE(b), h_VS, vrep.simx_opmode_streaming);
                sync = norm(l_position,2)~=0;
            end
            sync=false;
            
            zs_current(b)= l_position(3);
            us_current(b)= fl*l_position(1)/l_position(3);
            vs_currect(b)= fl*l_position(2)/l_position(3);
            
        end
        
        % _________________________________________________________________
        % _________________________________________________________________
        
        % 2) BUILDING POINT JACOBIAN
               
        % building the jacobian
        L = [ build_point_jacobian(us_current(1),vs_currect(1),zs_current(1),fl); ...
            build_point_jacobian(us_current(2),vs_currect(2),zs_current(2),fl); ...
            build_point_jacobian(us_current(3),vs_currect(3),zs_current(3),fl); ...
            build_point_jacobian(us_current(4),vs_currect(4),zs_current(4),fl)];

        % _________________________________________________________________
        % _________________________________________________________________
        
        % 3) COMPUTING IMAGE ERROR
        
        % computing the error
        err= [  us_desired(1,spot)-us_current(1); ...
                vs_desired(1,spot)-vs_currect(1); ...
                us_desired(2,spot)-us_current(2); ...
                vs_desired(2,spot)-vs_currect(2); ...
                us_desired(3,spot)-us_current(3); ...
                vs_desired(3,spot)-vs_currect(3); ...
                us_desired(4,spot)-us_current(4); ...
                vs_desired(4,spot)-vs_currect(4)        
              ];

        % _________________________________________________________________
        % _________________________________________________________________
        
        % 4) EVALUATING EXIT CONDITIONS
        
        % evaluating exit condition
        if norm(err,2)<=10^-4
            if spot==5 % last spot
                break;
            end
            mode=0;
            pause(2);
            fprintf(1, 'REACHED SPOT : %d \n', spot);
            continue;
        end
                
        if(mod(time,10)==0)
            plot(err,'--*');
            grid on
            % ylim([-1 1]*10^-4)
            title("image error");
        end
        
        % _________________________________________________________________
        % _________________________________________________________________
        
        % 6) COMPUTING THE DISPLACEMENT
        
        % computing the displacement
        ee_displacement_VS = K*pinv(-L)*err;
        
        if norm(ee_displacement_VS,2)<10^-2.5 %10^-2.9
            ee_displacement_VS = (ee_displacement_VS/norm(ee_displacement_VS,2))*10^-2.5;
        end
         
        % _________________________________________________________________
        % _________________________________________________________________
        
        % 7) GETTING THE POSE WRT VISION SENSOR [VS]
        
        while ~sync
            [~, ee_position_VS]=vrep.simxGetObjectPosition(ID, h_j6, h_VS, vrep.simx_opmode_streaming);
            sync = norm(ee_position_VS,2)~=0;
        end
        sync=false;
        
        while ~sync
            [~, ee_orientation_VS]=vrep.simxGetObjectOrientation(ID, h_j6, h_VS, vrep.simx_opmode_streaming);
            sync = norm(ee_orientation_VS,2)~=0;
        end
        sync=false;
        
        ee_pose_VS = [ee_position_VS, ee_orientation_VS]';
        
        % updating the pose
        next_ee_pose_VS = ee_pose_VS + ee_displacement_VS;
        
        if norm(ee_displacement_VS,2)<10^-2.5
            % non so cosa faccia ma l' ho preso dallo script originale
            ee_displacement_VS = (ee_displacement_VS/norm(ee_displacement_VS,2))*10^-2.5;
        end
        
        % _________________________________________________________________
             
        % distance between origins: VS_frame and RCM_frame (from VS -> RCM)
        % used below to get pose wrt RCM

        while ~sync
            [~, vs2rcm_position]=vrep.simxGetObjectPosition(ID, h_RCM ,h_VS, vrep.simx_opmode_streaming);
            [~, vs2rcm_orientation]=vrep.simxGetObjectOrientation(ID, h_RCM ,h_VS, vrep.simx_opmode_streaming);
            sync = norm(vs2rcm_position,2)~=0;
        end
        sync = false;
             
        vs2rcm = [vs2rcm_position';vs2rcm_orientation'];
        
        % _________________________________________________________________
        % _________________________________________________________________        
        
        % 8) GETTING THE POSE WRT RCM (error on orientation) [RCM]
        
        % this is the position of ee_pose wrt RCM frame
        ee_wrt_RCM = getRelativePosRCM(vs2rcm,ee_pose_VS);
        % this is the next position of ee_pose wrt RCM frame
        next_ee_wrt_RCM = getRelativePosRCM(vs2rcm,next_ee_pose_VS);

        while ~sync
            [~, rcmp]=vrep.simxGetObjectPosition(ID, h_j6 ,h_RCM, vrep.simx_opmode_streaming);
            [~, rcmo]=vrep.simxGetObjectOrientation(ID, h_j6 ,h_RCM, vrep.simx_opmode_streaming);
            sync = norm(rcmp,2)~=0;
        end

        real_rcm = [rcmp';rcmo'];
        
        % this is used to test if prediction is good
        % l' errore sull' orientamento è basso ma non capisco perche non
        % va.
        difference = utils.computeError(real_rcm, ee_wrt_RCM)
               
        % _________________________________________________________________
        % _________________________________________________________________  
        
        % error_rcm = zeros(6,1);
        % error_rcm(1) = -0.01; % simulo errore solo su z
        
        error_rcm = utils.computeError( next_ee_wrt_RCM, ee_wrt_RCM );
                
        % 9) CORRECT AND UPDATE POSE via INVERSE KINEMATICS
        
        % computing the new configuration via inverse inverse kinematics
        Q = kinematicsRCM.inverse_kinematics(Q, error_rcm, 1);
        
        % sending to joints
        [~] = vrep.simxSetJointPosition(ID, h_j1, Q(1), vrep.simx_opmode_streaming);
        [~] = vrep.simxSetJointPosition(ID, h_j2, Q(2), vrep.simx_opmode_streaming);
        [~] = vrep.simxSetJointPosition(ID, h_j3, Q(3), vrep.simx_opmode_streaming);
        [~] = vrep.simxSetJointPosition(ID, h_j4, Q(4), vrep.simx_opmode_streaming);
        [~] = vrep.simxSetJointPosition(ID, h_j5, Q(5), vrep.simx_opmode_streaming);
        [~] = vrep.simxSetJointPosition(ID, h_j6, Q(6), vrep.simx_opmode_streaming);
        pause(0.4);
        
    elseif mode == 0
        
        % see testing_mode0.m
        break
        
    end
    
    pause(0.05);
end

disp("############ PROCESS ENDED ############");

%%
%	FUNCTIONS
%%


function [clientID,vrep] = init_connection()

fprintf(1,'START...  \n');
vrep=remApi('remoteApi'); % using the prototype file (remoteApiProto.m)
vrep.simxFinish(-1); % just in case, close all opened connections
clientID=vrep.simxStart('127.0.0.1',19999,true,true,5000,5);
fprintf(1,'client %d\n', clientID);
if (clientID > -1)
    fprintf(1,'Connection: OK... \n');
else
    fprintf(2,'Connection: ERROR \n');
    return;
end
end

function [sync]  = syncronize(ID , vrep, h_j1, h_j2, h_j3, h_j4, h_j5, h_j6, h_7sx, h_7dx, h_RCM)
% to be prettyfied -> you will receive in input just (clientID , vrep, handles)
% h_EE = handles(1)
% h_j1_PSM = handles(2)
% ...

% used to wait to receive non zero values from vrep model
% usually matlab and vrep need few seconds to send valid values

sync = false;

while ~sync
    % i dont need them all, just one to check non-zero returning values
    [~,~] = vrep.simxGetJointPosition(ID, h_j1, vrep.simx_opmode_streaming);
    [~,~] = vrep.simxGetJointPosition(ID, h_j2, vrep.simx_opmode_streaming);
    [~,~] = vrep.simxGetJointPosition(ID, h_j3, vrep.simx_opmode_streaming);
    [~,~] = vrep.simxGetJointPosition(ID, h_j4, vrep.simx_opmode_streaming);
    [~,~] = vrep.simxGetJointPosition(ID, h_j5, vrep.simx_opmode_streaming);
    [~,some]=vrep.simxGetJointPosition(ID,h_j6,vrep.simx_opmode_streaming);
    
    [~,~] = vrep.simxGetJointPosition(ID, h_7sx, vrep.simx_opmode_streaming);
    [~,~] = vrep.simxGetJointPosition(ID, h_7dx, vrep.simx_opmode_streaming);
    
    [~,~] = vrep.simxGetJointPosition(ID, h_RCM, vrep.simx_opmode_streaming);
    
    [~, ee_position_relative]=vrep.simxGetObjectPosition(ID, h_j6, h_RCM, vrep.simx_opmode_streaming);
    [~, ee_orientation_relative]=vrep.simxGetObjectOrientation(ID, h_j6, h_RCM, vrep.simx_opmode_streaming);
    
    sync = norm(some,2)~=0;
end

end

function [J] = build_point_jacobian(u,v,z,fl)
J = [ -fl/z     0          u/z     (u*v)/fl        -(fl+(u^2)/fl)      v; ...
    0         -fl/z      v/z     (fl+(v^2)/fl)    -(u*v)/fl          -u];

end

function [relative] = getRelativePosRCM(vs2rcm,ee_pose)
% Knowing relative position of RCM frame and Vision Sensor frame 
% this method returns a pose in RCM frame, given a pose in VisionSensor Frame.
%
% vs2rcm : 6x1 vector of position and orientation of RCM wrt VS
% ee_pose : pose of EE wrt VS
% 
% extracting rot. matrix associated to orientation described in euler
% angles of rcm wrt vision sensor. 
% This is used in calculating the relative position
rotm_VS_RCM = eul2rotm(vs2rcm(4:6)', 'XYZ'); % vrep default eul represent.

% This rot. matrix is the one attached to the relative position of EE wrt
% Vision Sensor. 
% ee_pose(4:6) is an euler angles representation from which i get a rot.
% matrix. This is used in calculating the new orientation
rotm_VS_EE = eul2rotm(ee_pose(4:6)',  'XYZ');

% This is [x y z] expressed in RCM frame starting from [x y z] in VS reference.
relative_position = -(rotm_VS_RCM')*vs2rcm(1:3) + (rotm_VS_RCM')*ee_pose(1:3);

% This R4 matrix is the rotation matrix from RCM to EE 
% Is the result of concatenating RCM -> VS -> EE matrices
R4 = rotm_VS_RCM\rotm_VS_EE; % inv(RotMatrix)*R3 - same notation

% From this rotation matrix we extract euler angles orientation
relative_orientation = rotm2eul(R4,'XYZ'); % to be solved

% output
relative = [relative_position; relative_orientation'];

end

function [error] = computeError(desired, current)
% computes error between poses
error = [desired(1:3) - current(1:3); angdiff(current(4:6), desired(4:6))];

end 