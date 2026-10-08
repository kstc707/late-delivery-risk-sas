/*------------------------------------------------------------------------
  01_import_and_quality_checks.sas

  1. Read the raw line-item file (180,519 rows, 53 columns).
  2. Run data-quality checks before any modelling.
  3. Roll line items up to one row per order -> PROJ.ORDERS.

  Why one row per order: shipping mode, promised days, actual days and the
  late flag are recorded per ORDER and simply repeated on every line item.
  Modelling line items would count each shipment about 2.7 times and
  overstate every test statistic.

  Run 00_config.sas first.
------------------------------------------------------------------------*/

/*---------------------------- 1. Import ---------------------------------*/
/* The file has no embedded commas, quotes or line breaks, so an explicit
   INPUT statement is safer than PROC IMPORT guessing types and lengths.
   Columns that are not needed (names, street, masked e-mail and password,
   product image links) are read into _SKIP and dropped.                  */

data work.items_raw;
  infile "&root/data/DataCoSupplyChainDataset.csv"
         dlm=',' dsd firstobs=2 truncover lrecl=32767 encoding='wlatin1';

  length pay_type        $8
         delivery_status $20
         segment         $12
         department      $24
         market          $16
         order_country   $48
         order_dt_txt    $20
         order_region    $20
         order_status    $20
         product_desc    $8
         ship_dt_txt     $20
         ship_mode       $16
         _skip           $1;

  input pay_type        $   /*  1 Type                           */
        days_real           /*  2 Days for shipping (real)       */
        days_sched          /*  3 Days for shipment (scheduled)  */
        _skip           $   /*  4 Benefit per order              */
        _skip           $   /*  5 Sales per customer             */
        delivery_status $   /*  6 Delivery Status                */
        late_flag           /*  7 Late_delivery_risk             */
        _skip           $   /*  8 Category Id                    */
        _skip           $   /*  9 Category Name                  */
        _skip           $   /* 10 Customer City                  */
        _skip           $   /* 11 Customer Country               */
        _skip           $   /* 12 Customer Email (masked)        */
        _skip           $   /* 13 Customer Fname                 */
        customer_id         /* 14 Customer Id                    */
        _skip           $   /* 15 Customer Lname                 */
        _skip           $   /* 16 Customer Password (masked)     */
        segment         $   /* 17 Customer Segment               */
        _skip           $   /* 18 Customer State                 */
        _skip           $   /* 19 Customer Street                */
        _skip           $   /* 20 Customer Zipcode               */
        _skip           $   /* 21 Department Id                  */
        department      $   /* 22 Department Name                */
        _skip           $   /* 23 Latitude                       */
        _skip           $   /* 24 Longitude                      */
        market          $   /* 25 Market                         */
        _skip           $   /* 26 Order City                     */
        order_country   $   /* 27 Order Country                  */
        _skip           $   /* 28 Order Customer Id              */
        order_dt_txt    $   /* 29 order date (DateOrders)        */
        order_id            /* 30 Order Id                       */
        _skip           $   /* 31 Order Item Cardprod Id         */
        _skip           $   /* 32 Order Item Discount            */
        _skip           $   /* 33 Order Item Discount Rate       */
        order_item_id       /* 34 Order Item Id                  */
        _skip           $   /* 35 Order Item Product Price       */
        _skip           $   /* 36 Order Item Profit Ratio        */
        item_qty            /* 37 Order Item Quantity            */
        item_sales          /* 38 Sales                          */
        item_total          /* 39 Order Item Total               */
        _skip           $   /* 40 Order Profit Per Order         */
        order_region    $   /* 41 Order Region                   */
        _skip           $   /* 42 Order State                    */
        order_status    $   /* 43 Order Status                   */
        order_zip           /* 44 Order Zipcode                  */
        _skip           $   /* 45 Product Card Id                */
        _skip           $   /* 46 Product Category Id            */
        product_desc    $   /* 47 Product Description            */
        _skip           $   /* 48 Product Image                  */
        _skip           $   /* 49 Product Name                   */
        _skip           $   /* 50 Product Price                  */
        _skip           $   /* 51 Product Status                 */
        ship_dt_txt     $   /* 52 shipping date (DateOrders)     */
        ship_mode       $   /* 53 Shipping Mode                  */
        ;

  /* Last column on the line: strip a stray carriage return if the file
     was saved with Windows line endings.                               */
  ship_mode = compress(ship_mode, , 'c');

  /* Dates arrive as text such as 1/31/2018 22:56 */
  order_date = input(scan(order_dt_txt, 1, ' '), mmddyy10.);
  ship_date  = input(scan(ship_dt_txt,  1, ' '), mmddyy10.);
  format order_date ship_date date9.;

  drop _skip;
run;


/*------------------------ 2. Quality checks -----------------------------*/

title "QC 1 - Volume and date range (expect 180,519 line items, 65,752 orders)";
proc sql;
  select count(*)                 as line_items  format=comma12.,
         count(distinct order_id) as orders      format=comma12.,
         min(order_date)          as first_order format=date9.,
         max(order_date)          as last_order  format=date9.
  from work.items_raw;
quit;

title "QC 2 - Missing values in every column that was kept";
proc format;
  value $missfmt ' ' = 'Missing' other = 'Present';
  value  missfmt  .  = 'Missing' other = 'Present';
run;

proc freq data=work.items_raw;
  format _character_ $missfmt. _numeric_ missfmt.;
  tables _character_ / missing nocum;
  tables _numeric_   / missing nocum;
run;

title "QC 3 - Duplicate line-item keys (expect 0)";
proc sort data=work.items_raw out=work.items_nodup nodupkey dupout=work.dup_items;
  by order_item_id;
run;

proc sql;
  select count(*) as duplicate_line_items from work.dup_items;
quit;

title "QC 4 - Dates that failed to parse (expect 0)";
proc sql;
  select sum(missing(order_date)) as bad_order_dates,
         sum(missing(ship_date))  as bad_ship_dates
  from work.items_raw;
quit;

title "QC 5 - Orders whose shipping attributes differ across line items (expect 0)";
proc sql;
  select count(*) as inconsistent_orders
  from (select order_id
        from work.items_raw
        group by order_id
        having count(distinct ship_mode)       > 1
            or count(distinct late_flag)       > 1
            or count(distinct delivery_status) > 1
            or count(distinct days_real)       > 1
            or count(distinct days_sched)      > 1
            or count(distinct order_date)      > 1
            or count(distinct ship_date)       > 1
            or count(distinct market)          > 1
            or count(distinct segment)         > 1
            or count(distinct pay_type)        > 1);
quit;


/*------------------- 3. Roll up to one row per order --------------------*/
/* QC 5 confirms the order-level fields are constant within an order, so
   MAX() just picks that single value.                                    */

proc sql;
  create table proj.orders as
  select order_id,
         max(customer_id)     as customer_id,
         min(order_date)      as order_date  format=date9.,
         min(ship_date)       as ship_date   format=date9.,
         max(days_real)       as days_real,
         max(days_sched)      as days_sched,
         max(late_flag)       as late_flag,
         max(delivery_status) as delivery_status,
         max(order_status)    as order_status,
         max(ship_mode)       as ship_mode,
         max(market)          as market,
         max(order_region)    as order_region,
         max(segment)         as segment,
         max(pay_type)        as pay_type,
         count(*)             as n_items,
         sum(item_qty)        as total_qty,
         sum(item_total)      as order_total format=dollar12.2
  from work.items_raw
  group by order_id
  order by order_id;
quit;


/*------------------ Order-level reconciliation checks -------------------*/

title "QC 6 - Ship date minus order date vs recorded transit days (expect 0 mismatches)";
proc sql;
  select sum(intck('day', order_date, ship_date) ne days_real) as mismatched_orders
  from proj.orders;
quit;

/* The late flag should equal (actual days > scheduled days). It does for
   every delivered order. Cancelled orders are the exception: 1,650 of them
   took longer than scheduled yet carry late_flag = 0, so they would be
   counted as on-time. They are excluded from modelling in program 02.   */
data work.label_check;
  set proj.orders;
  took_longer = (days_real > days_sched);
run;

title "QC 7 - Label reconciliation: delivery status x took longer than scheduled x late flag";
proc freq data=work.label_check;
  tables delivery_status * took_longer * late_flag / list missing nocum;
run;

title "QC 8 - Order status of cancelled shipments";
proc freq data=proj.orders;
  where delivery_status = 'Shipping canceled';
  tables order_status / nocum;
run;

title;
