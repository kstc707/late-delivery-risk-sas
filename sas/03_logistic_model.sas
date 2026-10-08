/*------------------------------------------------------------------------
  03_logistic_model.sas

  Logistic regression for late delivery (late = 1), fitted on 2015-2016
  orders and scored on the 2017-2018 holdout.

  Step 1  Crude (single-predictor) screening
  Step 2  Backward elimination, SLSTAY = 0.10
  Step 3  Interaction check
  Step 4  Quasi-complete separation caused by First Class
  Step 5  Final model with Firth penalized likelihood, scored on holdout

  Run 00_config.sas, 01 and 02 first.
------------------------------------------------------------------------*/

data work.train work.holdout;
  set proj.delivered;
  if sample = 'Train' then output work.train;
  else output work.holdout;
run;

/* Every First Class order in the data is late, which makes the maximum
   likelihood estimate for that level infinite (Step 4). Steps 1-3 screen
   the remaining candidates on the other three modes, where ordinary
   maximum likelihood is well behaved.                                   */
data work.train_screen;
  set work.train;
  where ship_mode ne 'First Class';
run;


/*----------------------- Step 1. Crude screening ------------------------*/
%macro crude(effect, class=);
  title "Step 1 - Crude model: late = &effect";
  proc logistic data=work.train_screen;
    %if %length(&class) %then %do;
      class &class / param=ref;
    %end;
    model late(event='1') = &effect;
  run;
%mend crude;

%crude(ship_mode,  class=ship_mode(ref='Standard Class'));
%crude(market,     class=market(ref='USCA'));
%crude(segment,    class=segment(ref='Consumer'));
%crude(pay_type,   class=pay_type(ref='DEBIT'));
%crude(order_qtr,  class=order_qtr(ref='1'));
%crude(weekend);
%crude(n_items);
%crude(order_total_100);


/*-------------------- Step 2. Backward elimination ----------------------*/
title "Step 2 - Backward elimination from the full model (SLSTAY = 0.10)";
proc logistic data=work.train_screen;
  class ship_mode(ref='Standard Class') market(ref='USCA')
        segment(ref='Consumer') pay_type(ref='DEBIT') order_qtr(ref='1') / param=ref;
  model late(event='1') = ship_mode market segment pay_type order_qtr
                          weekend n_items order_total_100
        / selection=backward slstay=0.10;
run;


/*---------------------- Step 3. Interaction check -----------------------*/
/* Does the effect of shipping mode differ by market?                     */
title "Step 3 - Interaction: shipping mode x market";
proc logistic data=work.train_screen;
  class ship_mode(ref='Standard Class') market(ref='USCA') / param=ref;
  model late(event='1') = ship_mode market ship_mode*market;
run;


/*--------------------- Step 4. Separation problem -----------------------*/
/* Fitting shipping mode on ALL training orders by ordinary maximum
   likelihood. The log is expected to warn about quasi-complete separation
   and the First Class estimate and standard error are not usable.        */
title "Step 4 - Ordinary ML on all training orders (expect a separation warning in the log)";
proc logistic data=work.train;
  class ship_mode(ref='Standard Class') / param=ref;
  model late(event='1') = ship_mode;
run;


/*------------- Step 5. Final model, Firth penalized likelihood ----------*/
/* Firth's penalty gives finite estimates under separation.

   Model B keeps order value, which survived backward elimination with a
   borderline p-value. Model A drops it. FITSTAT prints the holdout AUC,
   Brier score and error rate for each so the two can be compared on data
   the model has not seen.                                                */

title "Step 5 - Model B (Firth): shipping mode + order value";
proc logistic data=work.train;
  class ship_mode(ref='Standard Class') / param=ref;
  model late(event='1') = ship_mode order_total_100 / firth;
  score data=work.holdout out=work.holdout_model_b fitstat;
run;

title "Step 5 - Model A (Firth, final): shipping mode";
proc logistic data=work.train;
  class ship_mode(ref='Standard Class') / param=ref;
  model late(event='1') = ship_mode / firth clodds=pl;
  score data=work.train   out=proj.train_scored   fitstat;
  score data=work.holdout out=proj.holdout_scored fitstat;
run;

/* The scored tables carry P_1 = predicted probability that late = 1.     */
title "Predicted late probability by shipping mode (holdout)";
proc means data=proj.holdout_scored n mean maxdec=4;
  class ship_mode;
  var P_1 late;
run;

title;
