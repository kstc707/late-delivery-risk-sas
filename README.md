# Late-Delivery Risk Modelling in SAS

Which orders arrive late, why, and does a model for it keep working after it is built?

A SAS project on 65,752 e-commerce orders: data-quality checks, chi-square tests, logistic regression with model selection, and month-by-month monitoring of the fitted model on later data.

**Tools:** SAS (DATA step, PROC SQL, FREQ, MEANS, TTEST, LOGISTIC, SGPLOT, macro, ODS), with a Python cross-check.

## What the analysis found

1. **Lateness is a promise problem, not a random one.** Of the order attributes tested here, only shipping mode is associated with late delivery. Market, customer segment, payment type, order size, quarter and weekend ordering show no association (chi-square p-values from 0.53 to 0.98).
2. **First Class is late every time.** It promises 1 day and takes exactly 2 days on all 9,602 delivered orders. That one service level accounts for 26.6% of all late deliveries, and a 2-day promise would have been met on every one of them.
3. **Among these candidates, a one-variable model is the right model.** Backward elimination kept shipping mode and, at a borderline p-value of 0.07, order value. Order value moved holdout AUC from 0.7427 to 0.7433, so it was dropped.
4. **The model held up after deployment.** Fitted on 2015–2016 and tracked over the next 13 months, monthly AUC stayed between 0.726 and 0.755 against 0.740 in training, and predicted late rates stayed within 1.8 points of observed. No month triggered an alert.
5. **Where operations should look first.** First Class and Second Class are 34.6% of orders and 53.6% of late deliveries.

## Results

Late delivery by shipping mode, all delivered orders:

| Shipping mode | Promised days | Actual days | Orders | Late | Late rate |
|---|---|---|---|---|---|
| First Class | 1 | 2 | 9,602 | 9,602 | 100.0% |
| Second Class | 2 | 2 to 6 | 12,256 | 9,803 | 80.0% |
| Same Day | 0 | 0 to 1 | 3,407 | 1,648 | 48.4% |
| Standard Class | 4 | 2 to 6 | 37,632 | 14,995 | 39.8% |
| **All** | | | **62,897** | **36,048** | **57.3%** |

Final model (Firth penalized likelihood, reference = Standard Class):

| Effect | Odds ratio |
|---|---|
| Second Class vs Standard Class | 6.02 |
| Same Day vs Standard Class | 1.28 |
| First Class vs Standard Class | not interpretable: every First Class order is late |

| Sample | Orders | AUC | Brier score | Error rate at 0.5 |
|---|---|---|---|---|
| Train (2015–2016) | 39,950 | 0.740 | 0.188 | 30.3% |
| Holdout (2017 – Jan 2018) | 22,947 | 0.743 | 0.188 | 30.5% |

Capture table on the holdout, riskiest tier first:

| Risk tier | Predicted late probability | Cumulative share of orders | Cumulative share of late deliveries |
|---|---|---|---|
| First Class | 1.00 | 15.1% | 26.4% |
| Second Class | 0.80 | 34.6% | 53.6% |
| Same Day | 0.46 | 40.1% | 58.6% |
| Standard Class | 0.40 | 100.0% | 100.0% |

## Approach

| Program | What it does |
|---|---|
| `sas/00_config.sas` | Project path, output library, monitoring tolerances. |
| `sas/01_import_and_quality_checks.sas` | Reads the 53-column raw file with an explicit INPUT statement, runs eight quality checks, rolls 180,519 line items up to one row per order. |
| `sas/02_explore_and_test.sas` | Builds the analysis table, splits it by time, tests each factor against late delivery. |
| `sas/03_logistic_model.sas` | Crude screening, backward elimination, an interaction check, the separation problem, and the final Firth model scored on the holdout. |
| `sas/04_monitoring.sas` | Monthly AUC and calibration against tolerances, shipping-mode mix drift, and the capture table. |

Decisions worth explaining:

- **One row per order, not per line item.** Shipping fields repeat on every line item. Modelling line items would count each shipment about 2.7 times and inflate every test statistic.
- **Cancelled orders are excluded.** 2,855 cancelled orders carry a late flag of 0, including 1,650 that took longer than scheduled. Keeping them would label those as on-time. For all 62,897 delivered orders the flag agrees exactly with actual days exceeding scheduled days.
- **Time-based split.** The model is fitted on 2015–2016 and evaluated on 2017 onward. A random split would hide drift, which is the thing the monitoring step exists to detect.
- **Firth's penalized likelihood.** Because every First Class order is late, ordinary maximum likelihood has no finite estimate for that level (quasi-complete separation). Firth's method gives finite estimates and usable predictions.
- **Monitoring tolerances.** A month is flagged when AUC falls more than 0.03 below training AUC or when observed and predicted late rates differ by more than 3 points. Both are set in `00_config.sas`.

## Limitations

- Order time of day was not tested here. A follow-up analysis in Python found that Same Day orders placed at or after noon are always late; adding that one term lifts holdout AUC from 0.743 to 0.774. It is the next change to make to this model.
- The dataset is a published teaching dataset. Its transit times are fixed or evenly spread within each shipping mode. Real carrier data would have route, weather and capacity effects.
- With one categorical predictor the model produces four distinct risk scores, so it ranks service levels rather than individual orders.
- The alert tolerances are judgment calls, not derived from a cost model.

## How to run

1. Get the data as described in [`data/README.md`](data/README.md).
2. Upload this folder to SAS (for example SAS OnDemand for Academics) and set `root` in `sas/00_config.sas` to its path.
3. Run the programs in order, `00` through `04`, in one session.

## Cross-check

`validation/crosscheck.py` is a separate Python implementation of every step, including its own Firth estimator. Its output is saved in [`validation/expected_results.txt`](validation/expected_results.txt), which is the source of the figures above and the reference for comparing the SAS listing.

```
pip install pandas numpy scipy statsmodels scikit-learn
python validation/crosscheck.py data/DataCoSupplyChainDataset.csv
```

## Background

The methods follow graduate coursework in Biostatistical Methods (University of Memphis): hypothesis testing, confounding and interaction checks, model selection and logistic regression, applied here to a logistics question. All code in this repository is original.

## Data source

Constante, F., Silva, F., Pereira, A. (2019). *DataCo Smart Supply Chain for Big Data Analysis*, Mendeley Data, V5. doi:10.17632/8gx2fvg2k6.5
