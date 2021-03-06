function [Data] = SelfPaceTM(Settings)


%% Define IP addresses
% bodyMass = Settings.BodyMass;
% IP.Talk2HostNic = '10.1.1.192'; %Cortex computer top port
% IP.HostNic = '10.1.1.198'; %Processing computer top port
IP.Treadmill = '127.0.0.1'; 
IP.Talk2HostNic = '127.0.0.1'; 
IP.HostNic = '127.0.0.1';

%% connect to treadmill and set initial speed
StartSpeed = Settings.StartSpeed; %m/s
r0 = calllib('treadmill0x2Dremote','TREADMILL_initializeUDP',IP.Treadmill,'4000');
r1 = calllib('treadmill0x2Dremote','TREADMILL_setSpeed',StartSpeed,StartSpeed,.25);
if r0 ~= 0 || r1 ~= 0
    disp('Treadmill Connection Error');
else
    disp('Connected to Treadmill'); 
    fprintf('Waiting for treadmill to reach walking speed... \n');
    pause(5); % Wait for treadmill to reach starting speed
    disp(['Treadmill set to ', num2str(StartSpeed), ' m/s']);
end

%% Initialize cortex communication variables
initializeStruct.TalkToHostNicCardAddress = IP.Talk2HostNic;
initializeStruct.HostNicCardAddress = IP.HostNic;
initializeStruct.HostMulticastAddress = '225.1.1.1';
initializeStruct.TalkToClientsNicCardAddress = '0';
initializeStruct.ClientsMulticastAddress = '225.1.1.2';

% Load the SDK libraries
r = mCortexExit(); % exit cortex 
returnValue = mCortexInitialize(initializeStruct); % initialize cortex
if returnValue ~= 0
    errordlg('Unable to initialize ethernet communication','Sample file error');
else
    disp('Connected to Cortex'); 
end

%% Initialize data structure and figures
MinBeltSpeed = 0.4; %m/s
MaxBeltSpeed = 2;
fprintf('Max Belt Speed = %.2f m/s \n',MaxBeltSpeed)
realtimeAccel = 0.6; % acceleration limiter
TreadmillCenter = 0.87; % treadmill center & dead zone center
% Exp = 2; % exponential factor to change speed outside dead zone
Linear = 0.10; % linear factor to change increase speed outside dead zone
DeadZone = 0.10; % set CoP dead zone distance (1 sided)

Frame = 1;
k=0; % initialize counter

L = Settings.FrameRate .* Settings.Duration; 
Data = struct([]); 
% Data(L).AnalogForces = [];
Data(L).Frame = [];
Data(L).F1Y = []; 
Data(L).F1Z = []; 
Data(L).F2Y = []; 
Data(L).F2Z = []; 
Data(L).CoP1y = []; 
Data(L).CoP2y = []; 
Data(L).CoP1x = []; 
Data(L).CoP2x = []; 
Data(L).RightOn = []; 
Data(L).LeftOn = []; 
Data(L).Time = []; 
Data(L).Speed = [];
Data(L).Fp = [];
Data(L).MeanPeakFp = [];

StopFig = figure(1); % create stop button
uicontrol(StopFig, 'Style', 'PushButton', 'String', 'Exit Figure to Stop', ...
    'Callback', 'delete(gcbo)', 'Position', [20 20 100 100]);

FeedbackFig = figure(2);
set(FeedbackFig, 'Position',[1000 100 800 550]); % create biofeedback figure

disp('Starting Trial');
tic; % create timer
startTime = datevec(now); % create elapsed timer

%% Self Pace Treadmill Controller Loop
% stops with button click
while isempty(StopFig) == 0 %ishandle(StopFig)
    drawnow;
    f = mGetCurrentFrame();
    timer = toc; 
    
    %% if new frame of data
    if f.iFrame>Frame
        k=k+1;
        Frame = f.iFrame;
        
        % extract analog forces
        F1Y = f.AnalogData.AnalogSamples(4,:);
        F1y = LoadScale('Fy', bits2volts(F1Y));
        F1Z = f.AnalogData.AnalogSamples(5,:);
        F1z = LoadScale('Fz', bits2volts(F1Z));
        F2Y = f.AnalogData.AnalogSamples(11,:);
        F2y = LoadScale('Fy', bits2volts(F2Y));
        F2Z = f.AnalogData.AnalogSamples(12,:);
        F2z = LoadScale('Fz', bits2volts(F2Z));
        
        if k == 1
            prevSpeed = StartSpeed;
        elseif k > 1
            prevSpeed = Data(k-1).Speed;
        end
        
        %% Save Treadmill data in structure
        % save force data in structure
        % Data(k).AnalogForces = frameOfData.AnalogData.Forces;
        Data(k).Frame = f.iFrame;
        % uncomment to save all cortex frame data
        %             Data(k).FrameData = frameOfData;
        
        % save converted forces (in N)
        Data(k).F1Y = F1y;
        Data(k).F1Z = F1z;
        Data(k).F2Y = F2y;
        Data(k).F2Z = F2z;
        
        % save CoPs
        Data(k).CoP1y = mean(f.AnalogData.Forces(3,1:2:end));
        Data(k).CoP2y = mean(f.AnalogData.Forces(3,2:2:end));
        Data(k).CoP1x = mean(f.AnalogData.Forces(4,1:2:end));
        Data(k).CoP2x = mean(f.AnalogData.Forces(4,2:2:end));
        
        % save whether time point is swing or stance for left and right
        Thresh = 25; % threshold for determining if a true vGRF
        if mean(Data(k).F1Z) > Thresh
            Data(k).RightOn = 1;
        else
            Data(k).RightOn = 0;
        end
        if mean(Data(k).F2Z) > Thresh
            Data(k).LeftOn = 1;
        else
            Data(k).LeftOn = 0;
        end
        
        
        %% if both feet on separate plates, calculate CoP
        if Data(k).LeftOn && Data(k).RightOn
            Data(k).CoPy = mean([Data(k).CoP1y Data(k).CoP2y]);
            RelCoPy = Data(k).CoPy - TreadmillCenter;
            AbsRelCoPy = abs(RelCoPy);
            diff = AbsRelCoPy - DeadZone;
            Sign = sign(RelCoPy); % direction of change
            
            if diff > 0 % if outside dead zone, change speed
                % new speed factor
                % SpeedChange = Sign .* diff.^Exp;
                SpeedChange = Sign .* diff .* Linear;
                
                % Calculate new speed, real component only
                newSpeed = real(prevSpeed + SpeedChange);
                
            else % if within dead zone, maintain current speed
                newSpeed = prevSpeed;
            end
            
        else
            newSpeed = prevSpeed;
        end
        
        %% Change speed of treadmill
        % bound new speed by set max & min
        if newSpeed > MaxBeltSpeed
            newSpeed = MaxBeltSpeed;
        elseif newSpeed < MinBeltSpeed
            newSpeed = MinBeltSpeed;
        end
        
        %set new speed
        if newSpeed ~= prevSpeed
            calllib('treadmill0x2Dremote','TREADMILL_setSpeed',newSpeed,newSpeed,realtimeAccel);
        end
        Data(k).Speed = newSpeed; % save speed
        
        %% Get current time
        currTime = datevec(now);
        ElapsedTime = etime(currTime, startTime);
        Data(k).Time = ElapsedTime; 
        
    end
    
    
    %% Plot all Biofeedback
    % helpful for de-bugging
%     if strcmp(Settings.Biofeedback, 'All')
%         % Plot real-time speed and forces
%         set(0,'CurrentFigure',FeedbackFig);
%         
%         subplot(3,2,[1 2]); hold on;
%         plot(k,newSpeed, '.k');
%         title('Speed');
%         
%         % define x-values for plotting 10 measures at a time
%         Offset = 0.01;
%         x = linspace(k, k+Offset*9, 10);
%         
%         % vertical ground reaction forces
%         % LEFT
%         subplot(323); hold on;
%         plot(x,Data(k).F2Z, '.k');
%         title('Left Vertical Force');
%         
%         % RIGHT
%         subplot(324); hold on;
%         plot(x,Data(k).F1Z, '.k');
%         title('Right Vertical Force');
%         
%         % anterior/posterior ground reaction forces
%         % aka propulsive & braking forces
%         % LEFT
%         subplot(325); hold on;
%         plot(x,Data(k).F2Y, '.k');
%         title('Left Propulsive Force');
%         
%         % RIGHT
%         subplot(326); hold on;
%         plot(x,Data(k).F1Y, '.k');
%         title('Right Propulsive Force');
%     end
    
    
    %% plot FP biofeedback
    if strcmp(Settings.Biofeedback, 'Fp') && k > 200
        
        % find peak propulsive force from previous step
        [Fp] = FindPrevFp(Data(k-199:k));
        MeanPeakFp = nanmean([Fp.LyPeak, Fp.RyPeak]);
        Data(k).Fp = Fp;
        Data(k).MeanPeakFp = MeanPeakFp;
        
        % plot biofeedback
        set(0,'CurrentFigure',FeedbackFig);
        x = [0 1 2];
        y1 = [Settings.TargetFp Settings.TargetFp  Settings.TargetFp];
        y2 = [MeanPeakFp MeanPeakFp MeanPeakFp];
        if abs(1 - MeanPeakFp / Settings.TargetFp) > 0.05
            Color = '-r';
        else
            Color = '-g';
        end
        plot(x ,y1,'-k',x,y2,Color,'LineWidth',4);
        
        % update title based on minutes completed
        if ElapsedTime < 60
            TitleStr = 'Fp Targeting';
        elseif ElapsedTime >= 60 && ElapsedTime < 120
            TitleStr = 'Fp Targeting - 1 min elapsed';
        elseif ElapsedTime >= 120 && ElapsedTime < 180
            TitleStr = 'Fp Targeting - 2 min elapsed';
        elseif ElapsedTime >= 180 && ElapsedTime < 240
            TitleStr = 'Fp Targeting - 3 min elapsed';
        elseif ElapsedTime >= 240
            TitleStr = 'Fp Targeting - 4 min elapsed';
        end
        title(TitleStr);
        
        ax = gca; % edit axes
        ax.XTick = [];
        ax.YTick = [];
        Lo = Settings.NormFp * 0.5;
        Hi = Settings.NormFp * 1.5;
        ax.YLim = [Lo Hi];
        
        % put elapsed time in contolfig
        if ishandle(StopFig)
            set(0,'CurrentFigure',StopFig)
            TimeStr = [num2str(floor(ElapsedTime)), ' seconds elapsed'];
            uipanel('Title',TimeStr, 'FontSize',12,...
                'BackgroundColor','white',...
                'Position',[.25 .1 .5 .5]);
        else
            break
        end
        
    end
    
    
    %% plot speed biofeedback
%     if strcmp(Settings.Biofeedback, 'Speed')
%         plot([0 1 2] ,[Settings.TargetSpeed Settings.TargetSpeed  Settings.TargetSpeed],...
%             '-k', 'LineWidth',2);
%         hold on;
%         L = plot([0 1 2],[newSpeed newSpeed  newSpeed],...
%             '-k', 'LineWidth',4);
%         if abs(1 - Settings.TargetSpeed / newSpeed) > 0.05
%             L.Color = 'r';
%         else
%             L.Color = 'g';
%         end
%         hold off;
%         title('Speed');
%         ax = gca; % edit axes
%         ax.XTick = [];
%         ax.YTick = [];
%         ax.YLim = [0 2];
%     end
    
    %% No biofeedback settings
    if strcmp(Settings.Biofeedback, 'None')
        close(FeedbackFig);
    end
    
    %% Stop treadmill when time limit reached or if StopFig deleted
    if timer > Settings.Duration
        close(StopFig);
        disp('Trial Duration Reached');
        break
    end
    
end

%% stop treadmill
disp('Stopping Treadmill');
speed = 0;
calllib('treadmill0x2Dremote','TREADMILL_initializeUDP',IP.Treadmill,'4000');
calllib('treadmill0x2Dremote','TREADMILL_setSpeed',speed, speed,.25);
close all;

% remove 1st row if empty
if isempty(Data(1).Frame)
    Data(1) = []; 
end

% remove empty rows at end
F = length([Data.Frame]) + 1;
if length(Data) > F
    Data(F:end) = []; 
end


end
