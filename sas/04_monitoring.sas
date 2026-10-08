/*------------------------------------------------------------------------
  04_monitoring.sas

  Track the final model month by month on the 2017-2018 holdout, as if it
  had been deployed at the end of 2016.

  For each month: orders scored, observed late rate, predicted late rate,
  calibration gap, AUC, and an alert when either tolerance in 00_config.sas
  is breached. Also: input-mix drift and a capture table for operations.

  Run 00_config.sas, 01, 02 and 03 first.
------------------------------------------------------------------------*/

/*------------------- Baseline: AUC on the training data -----------------*/
ods exclude all;
ods output ROCAssociation=work.base_roc;
proc logistic data=proj.train_scored;
  model late(event='1') = P_1 / nofit;
  roc 'Late-delivery model' pred=P_1;
run;
ods exclude none;

proc sql noprint;
  select Area into :base_auc trimmed from work.base_roc;
quit;
%put NOTE: Baseline (training) AUC = &base_auc;


/*----------------------- Monthly AUC on holdout -------------------------*/
proc sort data=proj.holdout_scored out=work.scored;
  by order_month;
run;

ods exclude all;
ods output ROCAssociation=work.month_roc;
proc logistic data=work.scored;
  by order_month;
  model late(event='1') = P_1 / nofit;
  roc 'Late-delivery model' pred=P_1;
run;
ods exclude none;


/*---------------- Monthly volume, late rates and accuracy ---------------*/
proc sql;
  create table work.month_stats as
  select order_month,
         count(*)                   as n_orders,
         mean(late)                 as observed_late_rate,
         mean(P_1)                  as predicted_late_rate,
         mean((P_1 >= 0.5) = late)  as accuracy
  from work.scored
  group by order_month
  order by order_month;
quit;

data proj.monitoring;
  merge work.month_stats
        work.month_roc(keep=order_month Area rename=(Area=auc));
  by order_month;

  calibration_gap = observed_late_rate - predicted_late_rate;
  auc_change      = auc - &base_auc;

  length alert $24;
  if auc_change < -&auc_tolerance then alert = 'AUC below tolerance';
  else if abs(calibration_gap) > &gap_tolerance then alert = 'Calibration drift';
  else alert = 'OK';

  format observed_late_rate predicted_late_rate calibration_gap accuracy percent8.1
         auc auc_change 6.3 n_orders comma8.;
  label order_month         = 'Order month'
        n_orders            = 'Orders scored'
        observed_late_rate  = 'Observed late rate'
        predicted_late_rate = 'Predicted late rate'
        calibration_gap     = 'Observed minus predicted'
        accuracy            = 'Accuracy at 0.5 cut-off'
        auc                 = 'AUC'
        auc_change          = 'AUC vs training'
        alert               = 'Alert';
run;

title "Model monitoring by month (training AUC = &base_auc)";
footnote "Alert when AUC is more than &auc_tolerance below training, or observed and predicted late rates differ by more than &gap_tolerance";
proc print data=proj.monitoring label noobs;
run;
footnote;

title "Months with an alert";
proc freq data=proj.monitoring;
  tables alert / nocum;
run;


/*------------------------------- Charts ---------------------------------*/
title "Monthly AUC on holdout";
proc sgplot data=proj.monitoring;
  series x=order_month y=auc / markers;
  refline &base_auc / axis=y label="Training AUC";
  refline %sysevalf(&base_auc - &auc_tolerance) / axis=y label="Alert threshold"
          lineattrs=(pattern=dash);
  xaxis label="Order month";
  yaxis label="AUC" min=0.5 max=1;
run;

title "Observed vs predicted late rate by month";
proc sgplot data=proj.monitoring;
  series x=order_month y=observed_late_rate  / markers legendlabel="Observed";
  series x=order_month y=predicted_late_rate / markers legendlabel="Predicted";
  xaxis label="Order month";
  yaxis label="Late-delivery rate";
run;


/*-------------------------- Input-mix drift -----------------------------*/
/* The model depends on shipping mode, so a shift in the mode mix is the
   first thing that would move its predictions.                           */
title "Shipping-mode mix by month (holdout)";
proc freq data=work.scored;
  tables order_month * ship_mode / chisq nocol nopercent;
run;


/*---------------- Capture table: where to look first --------------------*/
/* Predicted risk takes one value per shipping mode, so risk tiers are the
   modes ranked by predicted probability. Cumulative columns answer: if
   operations reviews the riskiest X% of orders, what share of late
   deliveries does that cover?                                            */
proc sql;
  create table work.tiers as
  select ship_mode,
         max(P_1)  as predicted_risk,
         count(*)  as n_orders,
         sum(late) as late_orders
  from proj.holdout_scored
  group by ship_mode
  order by predicted_risk desc;
quit;

proc sql noprint;
  select count(*), sum(late)
    into :tot_orders trimmed, :tot_late trimmed
  from proj.holdout_scored;
quit;

data proj.capture;
  set work.tiers;
  cum_orders + n_orders;
  cum_late   + late_orders;
  share_of_orders      = cum_orders / &tot_orders;
  share_of_late_caught = cum_late   / &tot_late;
  format predicted_risk 6.4 n_orders late_orders comma8.
         share_of_orders share_of_late_caught percent8.1;
  label ship_mode            = 'Risk tier (shipping mode)'
        predicted_risk       = 'Predicted late probability'
        n_orders             = 'Orders'
        late_orders          = 'Late orders'
        share_of_orders      = 'Cumulative share of orders'
        share_of_late_caught = 'Cumulative share of late deliveries';
  drop cum_orders cum_late;
run;

title "Capture table: riskiest tier first (holdout)";
proc print data=proj.capture label noobs;
run;

title;
