/*------------------------------------------------------------------------
  00_config.sas
  Run this first in every SAS session. The other programs rely on the
  macro variable ROOT and the library PROJ defined here.

  Folder layout expected under ROOT:
      data/DataCoSupplyChainDataset.csv    raw file (see data/README.md)
      output/                              created automatically
------------------------------------------------------------------------*/

/* EDIT THIS LINE: full path of the project folder.
   SAS OnDemand for Academics example: /home/u12345678/late-delivery-risk-sas */
%let root = /home/u00000000/late-delivery-risk-sas;

/* Monitoring tolerances used by 04_monitoring.sas */
%let auc_tolerance = 0.03;   /* alert if monthly AUC falls this far below training AUC */
%let gap_tolerance = 0.03;   /* alert if observed and predicted late rates differ by more */

options dlcreatedir nodate nonumber;
libname proj "&root/output";

ods graphics on;
title;
footnote;
