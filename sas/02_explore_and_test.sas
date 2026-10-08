/*------------------------------------------------------------------------
  02_explore_and_test.sas

  1. Build the analysis table PROJ.DELIVERED (cancelled orders removed,
     predictors derived, train / holdout period assigned).
  2. Describe late delivery by each candidate factor and test each
     association with a chi-square test.

  Run 00_config.sas and 01_import_and_quality_checks.sas first.
------------------------------------------------------------------------*/

/*----------------------- 1. Analysis table ------------------------------*/
data proj.delivered;
  set proj.orders;
  where delivery_status ne 'Shipping canceled';

  late            = late_flag;                       /* outcome: 1 = late  */
  weekend         = (weekday(order_date) in (1, 7)); /* ordered Sat or Sun */
  order_qtr       = qtr(order_date);
  order_total_100 = order_total / 100;               /* per 100 dollars    */
  order_month     = intnx('month', order_date, 0, 'b');
  format order_month yymmd7.;

  /* Time-based split: fit on 2015-2016, monitor on 2017 onward. A random
     split would hide any drift over time, which is what program 04 checks. */
  length sample $8;
  if order_date < '01JAN2017'd then sample = 'Train';
  else sample = 'Holdout';
run;

title "Delivered orders by sample period";
proc freq data=proj.delivered;
  tables sample * late / nocol nopercent;
run;


/*--------------------- 2. Late rate by factor ---------------------------*/

title "Late delivery by shipping mode (chi-square test of association)";
proc freq data=proj.delivered;
  tables ship_mode * late / chisq nocol nopercent;
run;

/* Promised days are fixed per mode, so lateness is driven by how actual
   transit time compares with that promise.                               */
title "Promised days and actual transit days by shipping mode";
proc freq data=proj.delivered;
  tables ship_mode * days_sched / nocol nopercent norow;
  tables ship_mode * days_real  / nocol nopercent;
run;

title "Late delivery by market, customer segment, payment type, quarter and weekend";
proc freq data=proj.delivered;
  tables (market segment pay_type order_qtr weekend) * late / chisq nocol nopercent;
run;

title "Order size by late status";
proc means data=proj.delivered n mean std median min max maxdec=2;
  class late;
  var order_total n_items total_qty;
run;

title "Two-sample t test: order value, late vs on-time";
proc ttest data=proj.delivered;
  class late;
  var order_total;
run;


/*----------------------------- 3. Charts --------------------------------*/

title "Share of orders delivered late, by shipping mode";
proc sgplot data=proj.delivered;
  vbar ship_mode / response=late stat=mean datalabel categoryorder=respdesc;
  xaxis label="Shipping mode";
  yaxis label="Share of orders delivered late" min=0 max=1;
run;

title "Actual transit days by shipping mode";
proc sgplot data=proj.delivered;
  vbox days_real / category=ship_mode;
  xaxis label="Shipping mode";
  yaxis label="Actual transit days";
run;

title;
