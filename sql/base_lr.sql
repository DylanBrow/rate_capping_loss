WITH
aod_em_combos AS (
  SELECT
    as_of_date_k,
    exposure_month_k
  FROM (
    SELECT
      edw.f_date_to_int(as_of_month.last_day_of_month) AS as_of_date_k,
      exposure_month.month_k AS exposure_month_k,
      ROW_NUMBER() OVER(PARTITION BY as_of_date_k ORDER BY exposure_month_k DESC)
    FROM edw.dim_month AS as_of_month
    JOIN edw.dim_month AS exposure_month ON exposure_month.month_k <= as_of_month.month_k
    join edw.dim_date on as_of_month.first_day_of_month = dim_date.date_actual
    WHERE dim_date.is_month_cls_ultimate_closed
      AND as_of_month.month_k >= 202001
      AND exposure_month.month_k >= 201801 AND exposure_month.month_k NOT IN (202003,202004,202005,202006)
  ) WHERE row_number <= 6
),
states_of_interest AS (
  SELECT
    aec.as_of_date_k,
    dr.market,
    dptr.loss_ratio_segment,
    dptr.policy_term_tenure,
    SUM(ffa.earned_on_level_premium_dollar_amount) AS olep,
    SUM(ffa.actuarial_ultimate_net_of_salsub_dollar_amount) AS a_ult,
    SUM(ffa.cls_ultimate_net_of_salsub_dollar_amount) AS cls_ult,
    SUM(ffa.reported_claim_count) AS reported_claims,
    CASE
        WHEN SUM(ffa.reported_claim_count) >= 500 THEN 1
        ELSE SQRT(SUM(ffa.reported_claim_count::FLOAT) / 500)
    END AS mkt_weight,
    1 - mkt_weight AS cw_weight,
    a_ult / olep::FLOAT AS a_ult_ollr,
    cls_ult / olep::FLOAT AS cls_ult_ollr
  FROM edw.fact_financials_accumulating ffa
  JOIN aod_em_combos aec ON aec.as_of_date_k = ffa.as_of_date_k AND aec.exposure_month_k = ffa.exposure_month_k
  JOIN edw.dim_date dd ON aec.as_of_date_k = dd.date_k
  JOIN edw.dim_rate dr ON dr.rate_k = ffa.actual_rate_k
  JOIN edw.dim_policy_term_revision dptr ON dptr.policy_term_revision_k = ffa.policy_term_revision_k
  LEFT JOIN lookup.bad_zip_codes bz ON dr.rating_zip = bz.zip_code
  JOIN edw.dim_account da ON da.account_scd_k = ffa.account_scd_k AND dd.end_of_day_timestamp BETWEEN da.valid_from and da.valid_to
  WHERE dptr.loss_ratio_segment IN ('DAY_ZERO_PRE_CLOSURE','NEW_BUSINESS')
  GROUP BY
    aec.as_of_date_k,
    dr.market,
    dptr.loss_ratio_segment,
    dptr.policy_term_tenure
  HAVING olep > 0
),
countrywide AS (
  SELECT
    aec.as_of_date_k,
    'CW' AS market,
    dptr.loss_ratio_segment,
    dptr.policy_term_tenure,
    SUM(ffa.earned_on_level_premium_dollar_amount) AS olep,
    SUM(ffa.actuarial_ultimate_net_of_salsub_dollar_amount) AS a_ult,
    SUM(ffa.cls_ultimate_net_of_salsub_dollar_amount) AS cls_ult,
    a_ult / olep::FLOAT AS a_ult_ollr,
    cls_ult / olep::FLOAT AS cls_ult_ollr
  FROM edw.fact_financials_accumulating ffa
  JOIN aod_em_combos aec ON aec.as_of_date_k = ffa.as_of_date_k AND aec.exposure_month_k = ffa.exposure_month_k
  JOIN edw.dim_date dd ON aec.as_of_date_k = dd.date_k
  JOIN edw.dim_rate dr ON dr.rate_k = ffa.actual_rate_k
  JOIN edw.dim_policy_term_revision dptr ON dptr.policy_term_revision_k = ffa.policy_term_revision_k
  LEFT JOIN lookup.bad_zip_codes bz ON dr.rating_zip = bz.zip_code
  JOIN edw.dim_account da ON da.account_scd_k = ffa.account_scd_k AND dd.end_of_day_timestamp BETWEEN da.valid_from and da.valid_to
  WHERE dptr.loss_ratio_segment IN ('DAY_ZERO_PRE_CLOSURE','NEW_BUSINESS')
  GROUP BY
    aec.as_of_date_k,
    dptr.loss_ratio_segment,
    dptr.policy_term_tenure
),
new_business AS (
  SELECT
  soi.as_of_date_k,
  soi.market,
  soi.policy_term_tenure,
  soi.loss_ratio_segment,
  soi.olep,
  soi.cls_ult,
  soi.reported_claims,
  soi.mkt_weight,
  soi.cw_weight,
  soi.cls_ult_ollr AS mkt_ult_ollr,
  cw.cls_ult_ollr AS cw_ult_ollr,
  (soi.mkt_weight * soi.cls_ult_ollr + soi.cw_weight * cw.cls_ult_ollr) AS cred_ult_ollr
  FROM states_of_interest soi
  JOIN countrywide cw ON cw.as_of_date_k = soi.as_of_date_k
                     AND cw.policy_term_tenure = soi.policy_term_tenure
                     AND cw.loss_ratio_segment = soi.loss_ratio_segment
  WHERE soi.loss_ratio_segment IN ('NEW_BUSINESS', 'DAY_ZERO_PRE_CLOSURE')
),
all_terms AS (
​
  SELECT
    as_of_date_k,
    market,
    2 AS policy_term_tenure,
    'RENEWAL' AS loss_ratio_segment,
    olep,
    cls_ult,
    reported_claims,
    mkt_weight,
    cw_weight,
    mkt_ult_ollr,
    cw_ult_ollr,
    cred_ult_ollr,
    cred_ult_ollr * 0.85 AS predicted_ollr
  FROM new_business
  WHERE loss_ratio_segment = 'NEW_BUSINESS'
​
  UNION ALL
​
  SELECT
    as_of_date_k,
    market,
    3 AS policy_term_tenure,
    'RENEWAL' AS loss_ratio_segment,
    olep,
    cls_ult,
    reported_claims,
    mkt_weight,
    cw_weight,
    mkt_ult_ollr,
    cw_ult_ollr,
    cred_ult_ollr,
    cred_ult_ollr * 0.85 * 0.97 AS predicted_ollr
  FROM new_business
  WHERE loss_ratio_segment = 'NEW_BUSINESS'
​
  UNION ALL
​
  SELECT
    as_of_date_k,
    market,
    4 AS policy_term_tenure,
    'RENEWAL' AS loss_ratio_segment,
    olep,
    cls_ult,
    reported_claims,
    mkt_weight,
    cw_weight,
    mkt_ult_ollr,
    cw_ult_ollr,
    cred_ult_ollr,
    cred_ult_ollr * 0.85 * 0.97 * 0.97 AS predicted_ollr
  FROM new_business
  WHERE loss_ratio_segment = 'NEW_BUSINESS'
​
  UNION ALL
​
  SELECT
    as_of_date_k,
    market,
    5 AS policy_term_tenure,
    'RENEWAL' AS loss_ratio_segment,
    olep,
    cls_ult,
    reported_claims,
    mkt_weight,
    cw_weight,
    mkt_ult_ollr,
    cw_ult_ollr,
    cred_ult_ollr,
    cred_ult_ollr * 0.85 * 0.97 * 0.97 * 0.97 AS predicted_ollr
  FROM new_business
  WHERE loss_ratio_segment = 'NEW_BUSINESS'
)
​
SELECT
  as_of_date_k,
  market,
  policy_term_tenure,
  predicted_ollr AS forecast_ollr
FROM all_terms
where policy_term_tenure >= 2
order by as_of_date_k desc, market, policy_term_tenure asc
