CREATE OR REPLACE PACKAGE BODY APPS.wwt_ds_so_promise_date_upd_pkg
AS
   -- CVS Header: $Source$, $Revision$, $Author$, $Date$
   --Github Header#
                                                                              /*
   -----------------------------------------------------------------------------
   |                                                                           |
   |Package Name        : wwt_ds_so_promise_date_upd_pkg                       |
   |                                                                           |
   |Description         : This package updates the promise date and schedule   |
   |                      ship date on drop ship sales order lines with the    |
   |                      associated purchase order line promise date.         |
   |                                                                           |
   |                                                                           |
   | Developer  Date         RFC      Rev  Description                         |
   | ---------  -----------  -------- ---- ------------------------------------|
   | kumarg     24-JUL-2009  CHG12338 1.1  Initial Creation of the package from|
   |                                       standalone procedure                |
   |                                       wwt_ds_so_promise_date_update.      |
   | kumarg     06-AUG-2009  CHG12338 1.2  1) Added func get_reserved_quantity |
   |                                       to get reserve qty for order line.  |
   |                                       2) Modified main proc's cursor to   |
   |                                       pick only shippable lines and has no|
   |                                       reserve/shipped quantities.         |
   |                                       3) Need Last Run Date to be lookup  |
   |                                       driven. Added procs get_last_run_date|
   |                                       and set_last_run_date for this.     |
   | kumarg     26-MAY-2010  CHG16007 1.3  Modified main proc, l_so_lines_cur  |
   |                                       cursor to improve performance.      |
   | deshmukh   13-DEC-2012  CHG24305 1.4  Modified cursor l_so_lines_cur      |
   |                                       to fetch the promise days update    |
   |                                       from lookup on the basis of ship to |
   |                                       country                             |
   | deshmukh   05-MAR-2013  CHG25091 1.5  1)Added NVL for prom_date_plus_days |
   |                                         column                            |
   |                                       2)Added EXISTS condition to check   |
   |                                         if program exist in lookup, so    |
   |                                         only those program would be       |
   |                                         considered for further processing |
   |bhatnags    25-JUL-2013  CHG26798 1.6  Modified logic for column           |
   |                                       prom_date_plus_days in cursor       |
   |                                       l_so_lines_cur for sales channel    |
   |                                       requirement                         |
   |kumarg      25-JUL-2013  CHG26798 1.7  Added max to avoid mutiple rows.    |
   |sreedhas    12-JUL-2016   R12     2.1  R12 Baseline                        |
   |mahambay    22-Jul-2016 STRY0643296 2.2 PO to SO promise date update changes|
   |                                        for drop ship as well as OE to PO  |
   |                                        orders to incorporate new vendor   |
   |                                        commit to ship date using transit  |
   |                                        time on PO carrier.                |
   |sreedhas   12-Oct-2016 INC0338085 2.3  Modified Main procedure. Add NVL to |
   |                                       drop ship when order date type code |
   |                                       is not arrival.                     |
   |sreedhas   06-Nov-2017 STRY0649052 2.4  When PO promise dates is updated on|
   |                                        a fully received PO, do not push   |
   |                                       PO promise date to the corresponding|
   |                                        Sales Order.                       |
   |gyanmotm   23-Mar-2018 INC0430047  2.5 Fixed Bug to update SO Promise date |
   |                                       only for Sales channels existing in |
   |                                       the lookup                          |
   | hazrab    03-JUL-2019 INC0537877  2.6 Added get_plla_promise_date         |
   |ramachad   26-JUN-2023 STRY0053562 2.7 B-46635 Exclude PromiseDate sync for|
                                           Business Complex Prog Sales Channels|
   |balasubs   22-JUL-2024 STRY0124130 2.27 Non-Shippable Line SSD Sync Calculation
   |panugabi   13-SEP-2024             2.9  Audit SSD SAD Changes              |
   |ramachad   10-DEC-2024 STRY0181426 3.0  Remove ComplexPrg for DropShip Line|
   |thakura    03-JUN-2026 STRY0355087 3.1 Assigning actual ship date from OTM to SSD on SO lines| 
   |                                       using the associated po lines having OTM enabled flag as Y when VCS and PD are NULL|
   -----------------------------------------------------------------------------
                                                                              */
   g_order_lines_stat_tbl        order_lines_stat_tbl_typ;
   g_org_id                      NUMBER := fnd_profile.VALUE('ORG_ID');
   
   
    /* -----------------------------------------------------------------------------
   | Procedure Name:  audit_new_values_ds_proc                                 |
   |                                                                           |
   | Description:  This Procedure used to audit new data of SSD,SAD            |
   |                 as part of drop ship sync                                 |
   | Developer  Date         RFC      Rev  Description                         |
   | ---------  -----------  -------- ---- ------------------------------------|                                                                          |
   |   panugabi 13-SEP-2024           2.9  Audit SSD SAD Changes               |
   -----------------------------------------------------------------------------
                                                                              */
   PROCEDURE audit_new_values_ds_proc(p_audit_batch_id   IN  NUMBER)
   IS
    l_source VARCHAR2(4000) := 'DROP SHIP SYNC';
	l_status VARCHAR2(4000):= FND_API.G_RET_STS_SUCCESS;
	l_table_name VARCHAR2(4000) := 'OE_ORDER_LINES_ALL';
   BEGIN
        
		wwt_omp_audit_utility_pkg.raise_audit_business_event (
				                x_status      => l_status,
                                p_source      => l_source,
                                p_table_name  => l_table_name,
                                p_batch_id    => p_audit_batch_id );  

        fnd_file.put_line(fnd_file.LOG,'Audit table update done with new values for batch_id='||p_audit_batch_id); 
		
   EXCEPTION WHEN OTHERS 
      THEN
      fnd_file.put_line(fnd_file.LOG, 'Error in audit new values procedure ' || SQLERRM);
   END;
   
   /* -----------------------------------------------------------------------------
   | Procedure Name:  audit_old_values_ds_proc                                 |
   |                                                                           |
   | Description:  This Procedure used to audit old data of SSD,SAD            |
   |                 as part of drop ship sync                                 |
   | Developer  Date         RFC      Rev  Description                         |
   | ---------  -----------  -------- ---- ------------------------------------|                                                                          |
   |   panugabi 13-SEP-2024           2.9  Audit SSD SAD Changes               |
   -----------------------------------------------------------------------------
                                                                              */
   PROCEDURE audit_old_values_ds_proc(
      p_line_tbl                 IN       oe_order_pub.line_tbl_type
     ,x_batch_id                   OUT      NUMBER
   )
   IS
      l_org_excluded varchar2(100) := 'N';
	  l_source_table varchar2(4000) := 'OE_ORDER_LINES_ALL';
	  l_source_column varchar2(4000) := 'SCHEDULE_SHIP_DATE';
	  l_ssd_reason_code varchar2(4000);
	  l_sad_reason_code varchar2(4000);
	  l_source varchar2(1000) := 'DROP SHIP SYNC';
	  l_batch_id number := 0;
	  l_index number;
	  l_audit_data  wwt_omp_audit_table_type:=wwt_omp_audit_table_type();
	  l_ship_from_org NUMBER;
	  l_sts varchar2(1000);
	  l_msg varchar2(4000);
	  l_ship_set_id number;
	  
	  cursor c_ship_set_lines is
	    select distinct oolset.line_id 
          from WWT.WWT_DROP_SHIP_AUDIT_GTT wdsag,
	               oe_order_lines_all oolset
          where 1=1
	       and oolset.ship_set_id = wdsag.ship_set_id
           and oolset.header_id = wdsag.header_id
	       and oolset.open_flag = 'Y'
	       and nvl(oolset.cancelled_flag,'N') = 'N';
	  
   BEGIN
          --fetch default reason codes
            BEGIN
			  
			        SELECT distinct attribute4
				      into l_ssd_reason_code
                      FROM apps.wwt_lookups_active_v wlav
                     WHERE wlav.lookup_type = 'WWT_DEFAULT_REASON_CODE'
                       AND wlav.attribute2 = l_source_table
                       and wlav.attribute1 = 'DROP SHIP SYNCH'
					   and wlav.enabled_flag = 'Y'
					   and wlav.attribute3 = 'SCHEDULE_SHIP_DATE';
					   
				     SELECT distinct attribute4
				       into l_sad_reason_code
                       FROM apps.wwt_lookups_active_v wlav
                      WHERE wlav.lookup_type = 'WWT_DEFAULT_REASON_CODE'
                       AND wlav.attribute2 = l_source_table
                       and wlav.attribute1 = 'DROP SHIP SYNCH'
					   and wlav.enabled_flag = 'Y'
					   and wlav.attribute3 = 'SCHEDULE_ARRIVAL_DATE';	   
				
		    EXCEPTION WHEN OTHERS THEN
			     l_ssd_reason_code := '';
				 l_sad_reason_code := '';
		    END;
      
	   FOR i IN 1 .. p_line_tbl.COUNT
        LOOP
		  BEGIN
		   
		      BEGIN
			  
			    select oola.ship_from_org_id,ship_set_id
				into l_ship_from_org,l_ship_set_id
				from oe_order_lines_all oola
				where oola.line_id = p_line_tbl(i).line_id
				and oola.header_id = p_line_tbl(i).header_id;
				
			  EXCEPTION WHEN OTHERS THEN
			     l_ship_from_org := 0;
			  END;
		   
		   wwt_omp_audit_utility_pkg.org_execlusion_validation_proc(l_ship_from_org,l_source_table,l_source_column,l_org_excluded);
			
             if l_org_excluded <> 'Y' then
			     
				 if p_line_tbl(i).schedule_ship_date is not null or p_line_tbl(i).schedule_arrival_date is not null
				 
				 then
				    
					if l_ship_set_id is null then
					
					l_audit_data.extend;
			        l_index:=l_audit_data.last;
			        l_audit_data(l_index):=wwt_omp_audit_rec_type(null,null,null,null);
			        l_audit_data(l_index).key_name:='LINE_ID';
			        l_audit_data(l_index).key_value:= p_line_tbl(i).line_id;
			        l_audit_data(l_index).audit_col_name:= 'SCHEDULE_SHIP_DATE';
			        l_audit_data(l_index).reason_code:= l_ssd_reason_code;
					
					 l_audit_data.extend;
			         l_index:=l_audit_data.last;
			         l_audit_data(l_index):=wwt_omp_audit_rec_type(null,null,null,null);
			         l_audit_data(l_index).key_name:='LINE_ID';
			         l_audit_data(l_index).key_value:= p_line_tbl(i).line_id;
			         l_audit_data(l_index).audit_col_name:= 'SCHEDULE_ARRIVAL_DATE';
			         l_audit_data(l_index).reason_code:= l_sad_reason_code;
					 
					 ELSE
					     BEGIN
					            INSERT INTO WWT.WWT_DROP_SHIP_AUDIT_GTT
						            (header_id,
						            ship_set_id
						            )
						        values
						            (p_line_tbl(i).header_id,
						            l_ship_set_id
						            );
						 EXCEPTION WHEN OTHERS then
						   fnd_file.put_line(fnd_file.LOG, 'Exception while inserting ship set lines:'|| SQLERRM);
						 END;
					 
					 end if; --ship_set 
					
				 end if; --ssd sad
				 
             end if; --org exclusion

           
		  EXCEPTION WHEN OTHERS then
			fnd_file.put_line(fnd_file.LOG, 'Exception in drop ship data audit collection:'|| SQLERRM);
          END;			 
			
		END LOOP;
		
		
		--Ship Set Lines Auditing
		
		  for r_ship_Set in c_ship_set_lines
		   loop
		            BEGIN
				    l_audit_data.extend;
			        l_index:=l_audit_data.last;
			        l_audit_data(l_index):=wwt_omp_audit_rec_type(null,null,null,null);
			        l_audit_data(l_index).key_name:='LINE_ID';
			        l_audit_data(l_index).key_value:= r_ship_Set.line_id;
			        l_audit_data(l_index).audit_col_name:= 'SCHEDULE_SHIP_DATE';
			        l_audit_data(l_index).reason_code:= l_ssd_reason_code;
					
					 l_audit_data.extend;
			         l_index:=l_audit_data.last;
			         l_audit_data(l_index):=wwt_omp_audit_rec_type(null,null,null,null);
			         l_audit_data(l_index).key_name:='LINE_ID';
			         l_audit_data(l_index).key_value:= r_ship_Set.line_id;
			         l_audit_data(l_index).audit_col_name:= 'SCHEDULE_ARRIVAL_DATE';
			         l_audit_data(l_index).reason_code:= l_sad_reason_code;
					 
					  EXCEPTION WHEN OTHERS THEN
			           fnd_file.put_line(fnd_file.LOG, 'Exception while auditing ship set lines:'|| SQLERRM);
			        END;
			 
		   END LOOP;
		
		 if l_audit_data.count>0 then
		  
		      wwt_omp_audit_utility_pkg.insert_old_values_prc (
                                        p_table_name   =>l_source_table,
                                        p_source       =>l_source,
                                        p_audited_by   =>fnd_global.user_id,
                                        p_audit_date   =>sysdate,
                                        p_audit_data   =>l_audit_data,
                                        x_batch_id     =>l_batch_id,
                                        x_status       =>l_sts,
                                        x_message      =>l_msg
                                         );
                
				l_audit_data.delete;
				
				DELETE FROM WWT.WWT_DROP_SHIP_AUDIT_GTT;
				
                IF l_sts<>FND_API.G_RET_STS_SUCCESS THEN
                      fnd_file.put_line(fnd_file.LOG, 'Error in wwt_omp_audit_utility_pkg.insert_old_values_prc ' || l_msg);
                END IF ; 
		end if;  
		
		x_batch_id := l_batch_id;
   
   EXCEPTION WHEN OTHERS THEN
      x_batch_id := 0;
	  fnd_file.put_line(fnd_file.LOG, 'Error in wwt_omp_audit_utility_pkg.audit_old_values_ds_proc ' || SQLERRM);
   END;

                                                                              /*
   -----------------------------------------------------------------------------
   | Procedure Name:  get_reserved_quantity                                    |
   |                                                                           |
   | Description:  This function used to get the Reserved Quantity for an order|
   |               Line.                                                       |
   |                                                                           |
   -----------------------------------------------------------------------------
                                                                              */
   FUNCTION get_reserved_quantity(
      p_line_id                  IN       NUMBER
   )
      RETURN NUMBER
   IS
      l_reserved_quantity           NUMBER;
   BEGIN
      wwt_runtime_utilities.DEBUG(1, 'Begin get_reserved_quantity');
      wwt_runtime_utilities.DEBUG(1, 'Input Parameters: ');
      wwt_runtime_utilities.DEBUG(1,  '  p_line_id = ' || p_line_id);

      SELECT NVL(SUM(reservation_quantity), 0)
        INTO l_reserved_quantity
        FROM mtl_reservations mr
       WHERE mr.demand_source_line_id = p_line_id
         AND mr.demand_source_type_id = 2   -- SOURCE_TYPE_OE
         AND mr.supply_source_type_id = 13;   --SOURCE_TYPE_INV

      wwt_runtime_utilities.DEBUG(1, 'End get_reserved_quantity');
      RETURN(l_reserved_quantity);
   EXCEPTION
      WHEN OTHERS
      THEN
         wwt_runtime_utilities.DEBUG(1,  'Exception1 in get_reserved_quantity. Error ' || SQLERRM);
         RETURN(0);
   END get_reserved_quantity;

                                                                              /*
   -----------------------------------------------------------------------------
   | Procedure Name:  get_last_run_date                                        |
   |                                                                           |
   | Description:  This function used to get the Last Run Date of conc program.|
   |                                                                           |
   -----------------------------------------------------------------------------
                                                                              */
   PROCEDURE get_last_run_date(
      x_last_run_date            OUT      DATE
     ,x_status                   OUT      VARCHAR2
   )
   IS
   BEGIN
      wwt_runtime_utilities.DEBUG(1, 'Begin get_last_run_date');

      SELECT NVL(TO_DATE(attribute2, 'DD-MON-RRRR HH24:MI:SS'), SYSDATE)
        INTO x_last_run_date
        FROM wwt_lookups
       WHERE lookup_type = 'WWT_ONT_PROMISE_DATE_UPDATE'
         AND attribute1 = g_org_id
         AND enabled_flag = 'Y'
         AND TRUNC(SYSDATE) BETWEEN NVL(start_date_active, TRUNC(SYSDATE)) AND NVL(end_date_active, TRUNC(SYSDATE));

      x_status := 'S';
      wwt_runtime_utilities.DEBUG(1, 'End get_last_run_date');
   EXCEPTION
      WHEN NO_DATA_FOUND
      THEN
         wwt_runtime_utilities.DEBUG(1, 'No data found in get_last_run_date.');
         x_status := 'E';
      WHEN OTHERS
      THEN
         wwt_runtime_utilities.DEBUG(1,  'Exception1 in get_last_run_date. Error ' || SQLERRM);
         x_status := 'E';
   END get_last_run_date;

                                                                              /*
   -----------------------------------------------------------------------------
   | Function Name:  get_promise_date                                          |
   |                                                                           |
   | Description:  This function used to get the Promise Date for an order     |
   |               Line.                                                       |
   |                                                                           |
   -----------------------------------------------------------------------------
                                                                              */
   FUNCTION get_plla_promise_date(
      p_line_flow                IN       VARCHAR2
     ,p_order_date_type_code     IN       VARCHAR2
     ,p_promised_date            IN       VARCHAR2
     ,p_vendor_commit_to_ship    IN       VARCHAR2
   )
      RETURN DATE
   IS
      l_promise_date                DATE;
   BEGIN
      wwt_runtime_utilities.DEBUG(1, 'Begin get_plla_promise_date');
      wwt_runtime_utilities.DEBUG(1, 'Input Parameters: ');
      wwt_runtime_utilities.DEBUG(1,  '  p_line_flow = ' || p_line_flow);
      wwt_runtime_utilities.DEBUG(1,  '  p_order_date_type_code = ' || p_order_date_type_code);
      wwt_runtime_utilities.DEBUG(1,  '  p_promised_date = ' || p_promised_date);
      wwt_runtime_utilities.DEBUG(1,  '  p_vendor_commit_to_ship = ' || p_vendor_commit_to_ship);

      IF     p_line_flow = 'DROP_SHIP'
         AND p_order_date_type_code = 'ARRIVAL'
      THEN
         l_promise_date := p_promised_date;
      ELSE
         l_promise_date := NVL(TRUNC(TO_DATE(p_vendor_commit_to_ship, 'YYYY/MM/DD HH24:MI:SS')), p_promised_date);
      END IF;

      IF l_promise_date IS NULL
      THEN
         l_promise_date := SYSDATE;
      END IF;

      RETURN(l_promise_date);
   EXCEPTION
      WHEN OTHERS
      THEN
         wwt_runtime_utilities.DEBUG(1,  'Exception in get_plla_promise_date. Error '
                                      || SQLERRM);
         RETURN(SYSDATE);
   END get_plla_promise_date;

                                                                              /*
   -----------------------------------------------------------------------------
   | Procedure Name:  set_last_run_date                                        |
   |                                                                           |
   | Description:  This function used to set the Last Run Date of conc program.|
   |                                                                           |
   -----------------------------------------------------------------------------
                                                                              */
   PROCEDURE set_last_run_date(
      p_last_run_date            IN       DATE
     ,x_status                   OUT      VARCHAR2
   )
   IS
   BEGIN
      wwt_runtime_utilities.DEBUG(1, 'Begin set_last_run_date');

      UPDATE wwt_lookups
         SET attribute2 = TO_CHAR(p_last_run_date, 'DD-MON-RRRR HH24:MI:SS')
       WHERE lookup_type = 'WWT_ONT_PROMISE_DATE_UPDATE'
         AND attribute1 = g_org_id
         AND enabled_flag = 'Y'
         AND TRUNC(SYSDATE) BETWEEN NVL(start_date_active, TRUNC(SYSDATE)) AND NVL(end_date_active, TRUNC(SYSDATE));

      x_status := 'S';
      wwt_runtime_utilities.DEBUG(1, 'End set_last_run_date');
   EXCEPTION
      WHEN OTHERS
      THEN
         wwt_runtime_utilities.DEBUG(1,  'Exception1 in set_last_run_date. Error '
                                      || SQLERRM);
         x_status := 'E';
   END set_last_run_date;

                                                                              /*
   -----------------------------------------------------------------------------
   | Procedure Name:  print_details                                            |
   |                                                                           |
   | Description:  This Procedure used to print the summary of the order lines |
   |               processed.                                                  |
   |                                                                           |
   -----------------------------------------------------------------------------
                                                                              */
   PROCEDURE print_details(
      p_status                   IN       VARCHAR2
   )
   IS
   BEGIN
      wwt_runtime_utilities.DEBUG(1, 'Begin print_details  ');
      wwt_runtime_utilities.DEBUG(1,  ' p_status = ' || p_status);

   -- Print headings
      IF p_status = 'Success'
      THEN
         fnd_file.put_line(fnd_file.LOG, ' ');
         fnd_file.put_line(fnd_file.LOG, 'Update Process Success Log Report Follows:');
         fnd_file.put_line(fnd_file.LOG, LPAD('Scheduled Date', 83, ' '));
         fnd_file.put_line(fnd_file.LOG
                          ,    LPAD('Order #', 10, ' ')
                            || ' '
                            || LPAD('Line #', 6, ' ')
                            || ' '
                            || RPAD('Buyer Name', 40, ' ')
                            || ' '
                            || RPAD('Date Type', 9, ' ')
                            || ' '
                            || RPAD('New Value', 15, ' ')
                            || ' '
                            || RPAD('Status', 10, ' '));
         fnd_file.put_line(fnd_file.LOG
                          ,    LPAD('-', 10, '-')
                            || ' '
                            || LPAD('-', 6, '-')
                            || ' '
                            || RPAD('-', 40, '-')
                            || ' '
                            || RPAD('-', 9, '-')
                            || ' '
                            || RPAD('-', 15, '-')
                            || ' '
                            || RPAD('-', 10, '-'));
      ELSIF p_status = 'Error'
      THEN
         fnd_file.put_line(fnd_file.LOG, ' ');
         fnd_file.put_line(fnd_file.LOG, 'Update Process Error Log Report Follows:');
         fnd_file.put_line(fnd_file.LOG, LPAD('Scheduled Date', 83, ' '));
         fnd_file.put_line(fnd_file.LOG
                          ,    LPAD('Order #', 10, ' ')
                            || ' '
                            || LPAD('Line #', 6, ' ')
                            || ' '
                            || RPAD('Buyer Name', 40, ' ')
                            || ' '
                            || RPAD('Date Type', 9, ' ')
                            || ' '
                            || RPAD('New Value', 15, ' ')
                            || ' '
                            || RPAD('Status', 10, ' ')
                            || ' '
                            || RPAD('Error', 200, ' '));
         fnd_file.put_line(fnd_file.LOG
                          ,    LPAD('-', 10, '-')
                            || ' '
                            || LPAD('-', 6, '-')
                            || ' '
                            || RPAD('-', 40, '-')
                            || ' '
                            || RPAD('-', 9, '-')
                            || ' '
                            || RPAD('-', 15, '-')
                            || ' '
                            || RPAD('-', 10, '-')
                            || ' '
                            || RPAD('-', 200, '-'));
      END IF;

      -- Print the details
      FOR l_ctr IN 1 .. g_order_lines_stat_tbl.COUNT
      LOOP
         IF     g_order_lines_stat_tbl(l_ctr).status = p_status
            AND p_status = 'Success'
         THEN
            fnd_file.put_line(fnd_file.LOG
                             ,    LPAD(g_order_lines_stat_tbl(l_ctr).order_number, 10, ' ')
                               || ' '
                               || LPAD(g_order_lines_stat_tbl(l_ctr).line_number, 6, ' ')
                               || ' '
                               || RPAD(NVL(g_order_lines_stat_tbl(l_ctr).buyer_name, ' '), 40, ' ')
                               || ' '
                               || RPAD(NVL(g_order_lines_stat_tbl(l_ctr).order_date_type_code, ' '), 9, ' ')
                               || ' '
                               || RPAD(NVL(TO_CHAR(g_order_lines_stat_tbl(l_ctr).schedule_ship_date, 'DD-MON-RRRR'), ' '), 15, ' ')
                               || ' '
                               || RPAD(g_order_lines_stat_tbl(l_ctr).status, 10, ' '));
         ELSIF     g_order_lines_stat_tbl(l_ctr).status <> 'Success'
               AND p_status = 'Error'
         THEN
            fnd_file.put_line(fnd_file.LOG
                             ,    LPAD(g_order_lines_stat_tbl(l_ctr).order_number, 10, ' ')
                               || ' '
                               || LPAD(g_order_lines_stat_tbl(l_ctr).line_number, 6, ' ')
                               || ' '
                               || RPAD(NVL(g_order_lines_stat_tbl(l_ctr).buyer_name, ' '), 40, ' ')
                               || ' '
                               || RPAD(NVL(g_order_lines_stat_tbl(l_ctr).order_date_type_code, ' '), 9, ' ')
                               || ' '
                               || RPAD(NVL(TO_CHAR(g_order_lines_stat_tbl(l_ctr).schedule_ship_date, 'DD-MON-RRRR'), ' '), 15, ' ')
                               || ' '
                               || RPAD(g_order_lines_stat_tbl(l_ctr).status, 10, ' ')
                               || ' '
                               || RPAD(g_order_lines_stat_tbl(l_ctr).error_message, 200, ' '));
         END IF;
      END LOOP;

      --Print Footer line
      IF p_status = 'Success'
      THEN
         fnd_file.put_line(fnd_file.LOG
                          ,    LPAD('-', 10, '-')
                            || ' '
                            || LPAD('-', 6, '-')
                            || ' '
                            || RPAD('-', 40, '-')
                            || ' '
                            || RPAD('-', 9, '-')
                            || ' '
                            || RPAD('-', 15, '-')
                            || ' '
                            || RPAD('-', 10, '-'));
      ELSIF p_status = 'Error'
      THEN
         fnd_file.put_line(fnd_file.LOG
                          ,    LPAD('-', 10, '-')
                            || ' '
                            || LPAD('-', 6, '-')
                            || ' '
                            || RPAD('-', 40, '-')
                            || ' '
                            || RPAD('-', 9, '-')
                            || ' '
                            || RPAD('-', 15, '-')
                            || ' '
                            || RPAD('-', 10, '-')
                            || ' '
                            || RPAD('-', 200, '-'));
      END IF;

      wwt_runtime_utilities.DEBUG(1, 'End print_details  ');
   EXCEPTION
      WHEN OTHERS
      THEN
         fnd_file.put_line(fnd_file.LOG, 'print_details WHEN OTHERS EXCEPTION1 ' || SQLERRM);
         wwt_runtime_utilities.flush_message_stack;
         RAISE;
   END print_details;

                                                                              /*
   -----------------------------------------------------------------------------
   | Procedure Name:  call_process_order_api                                   |
   |                                                                           |
   | Description:  This Procedure used to call the process order api and then  |
   |               populate the details of the lines processed in global stats |
   |               pl/sql table.                                               |
   |                                                                           |
   -----------------------------------------------------------------------------
                                                                              */
   PROCEDURE call_process_order_api(
      p_line_tbl                 IN       oe_order_pub.line_tbl_type
     ,p_order_number             IN       NUMBER
     ,p_buyer_name               IN       VARCHAR2
     ,p_order_date_type_code     IN       VARCHAR2
     ,x_status                   OUT      VARCHAR2
   )
   IS
      --l_status                      VARCHAR2(10);
      l_message                     VARCHAR2(2000);
      l_err_message                 VARCHAR2(2000);
      l_msg_idx_out                 NUMBER;
      l_stat_tbl_ctr                NUMBER := 0;
      x_return_status               VARCHAR2(80);
      x_msg_count                   NUMBER;
      x_msg_data                    VARCHAR2(2000);
      x_header_rec                  oe_order_pub.header_rec_type;
      x_header_val_rec              oe_order_pub.header_val_rec_type;
      x_header_adj_tbl              oe_order_pub.header_adj_tbl_type;
      x_header_adj_val_tbl          oe_order_pub.header_adj_val_tbl_type;
      x_header_price_att_tbl        oe_order_pub.header_price_att_tbl_type;
      x_header_adj_att_tbl          oe_order_pub.header_adj_att_tbl_type;
      x_header_adj_assoc_tbl        oe_order_pub.header_adj_assoc_tbl_type;
      x_header_scredit_tbl          oe_order_pub.header_scredit_tbl_type;
      x_header_scredit_val_tbl      oe_order_pub.header_scredit_val_tbl_type;
      x_line_tbl                    oe_order_pub.line_tbl_type;
      x_line_val_tbl                oe_order_pub.line_val_tbl_type;
      x_line_adj_tbl                oe_order_pub.line_adj_tbl_type;
      x_line_adj_val_tbl            oe_order_pub.line_adj_val_tbl_type;
      x_line_price_att_tbl          oe_order_pub.line_price_att_tbl_type;
      x_line_adj_att_tbl            oe_order_pub.line_adj_att_tbl_type;
      x_line_adj_assoc_tbl          oe_order_pub.line_adj_assoc_tbl_type;
      x_line_scredit_tbl            oe_order_pub.line_scredit_tbl_type;
      x_line_scredit_val_tbl        oe_order_pub.line_scredit_val_tbl_type;
      x_lot_serial_tbl              oe_order_pub.lot_serial_tbl_type;
      x_lot_serial_val_tbl          oe_order_pub.lot_serial_val_tbl_type;
      x_action_request_tbl          oe_order_pub.request_tbl_type;
	  l_audit_batch_id number := 0; --Added by Bindu for 2.9 version Audit Changes
   BEGIN
      wwt_runtime_utilities.DEBUG(1, 'Begin call_process_order_api  ');
      wwt_runtime_utilities.DEBUG(1, ' p_line_tbl = <pl/sql table>');
      wwt_runtime_utilities.DEBUG(1,  ' p_order_number = '
                                   || p_order_number);
      wwt_runtime_utilities.DEBUG(1,  ' p_buyer_name = '
                                   || p_buyer_name);
								   
								   
	  audit_old_values_ds_proc(p_line_tbl,l_audit_batch_id); --Added by Bindu for 2.9 version Audit Changes  	
	  
								   
      --Call API
      oe_order_pub.process_order(p_api_version_number     => 1.0
                                ,p_init_msg_list          => fnd_api.g_true
                                ,p_line_tbl               => p_line_tbl
                                ,x_return_status          => x_return_status
                                ,x_msg_count              => x_msg_count
                                ,x_msg_data               => x_msg_data
                                ,x_header_rec             => x_header_rec
                                ,x_header_val_rec         => x_header_val_rec
                                ,x_header_adj_tbl         => x_header_adj_tbl
                                ,x_header_adj_val_tbl     => x_header_adj_val_tbl
                                ,x_header_price_att_tbl   => x_header_price_att_tbl
                                ,x_header_adj_att_tbl     => x_header_adj_att_tbl
                                ,x_header_adj_assoc_tbl   => x_header_adj_assoc_tbl
                                ,x_header_scredit_tbl     => x_header_scredit_tbl
                                ,x_header_scredit_val_tbl => x_header_scredit_val_tbl
                                ,x_line_tbl               => x_line_tbl
                                ,x_line_val_tbl           => x_line_val_tbl
                                ,x_line_adj_tbl           => x_line_adj_tbl
                                ,x_line_adj_val_tbl       => x_line_adj_val_tbl
                                ,x_line_price_att_tbl     => x_line_price_att_tbl
                                ,x_line_adj_att_tbl       => x_line_adj_att_tbl
                                ,x_line_adj_assoc_tbl     => x_line_adj_assoc_tbl
                                ,x_line_scredit_tbl       => x_line_scredit_tbl
                                ,x_line_scredit_val_tbl   => x_line_scredit_val_tbl
                                ,x_lot_serial_tbl         => x_lot_serial_tbl
                                ,x_lot_serial_val_tbl     => x_lot_serial_val_tbl
                                ,x_action_request_tbl     => x_action_request_tbl
                                );
      wwt_runtime_utilities.DEBUG(p_level                  => 2, p_text => 'x_return_status = '
                                                               || x_return_status);

      IF (x_return_status != fnd_api.g_ret_sts_success)
      THEN
         wwt_runtime_utilities.DEBUG(2, 'Process Order API failed, messages follow:');
         l_err_message := NULL;

         FOR l_msg_idx IN 1 .. x_msg_count
         LOOP
            -- Get the message off the OM message stack.
            oe_msg_pub.get(p_msg_index              => l_msg_idx
                          ,p_encoded                => fnd_api.g_false
                          ,p_data                   => l_message
                          ,p_msg_index_out          => l_msg_idx_out
                          );
            wwt_runtime_utilities.DEBUG(3,  'Error Msg: ' || l_message);
            l_err_message := SUBSTR(   l_err_message || l_message ,1 ,2000 );
         END LOOP;
      END IF;

      --Initialize the return status
      IF (x_return_status != fnd_api.g_ret_sts_success)
      THEN
         x_status := 'Error';
      ELSE
         x_status := 'Success';
		 
		 if l_audit_batch_id IS NOT NULL AND l_audit_batch_id > 0
		    then
		      audit_new_values_ds_proc(l_audit_batch_id); --Added by Bindu for 2.9 version Audit Changes 
		   end if;
		 
      END IF;

      -- Populate stats table to print the Success/Error Log
      FOR i IN 1 .. p_line_tbl.COUNT
      LOOP
         l_stat_tbl_ctr :=   NVL(g_order_lines_stat_tbl.COUNT, 0) + 1;
         g_order_lines_stat_tbl(l_stat_tbl_ctr).order_number := p_order_number;
         g_order_lines_stat_tbl(l_stat_tbl_ctr).line_number := p_line_tbl(i).line_number;
         g_order_lines_stat_tbl(l_stat_tbl_ctr).order_date_type_code := NVL(p_order_date_type_code, 'SHIP');
         g_order_lines_stat_tbl(l_stat_tbl_ctr).buyer_name := p_buyer_name;

         IF p_order_date_type_code = 'ARRIVAL'
         THEN
            g_order_lines_stat_tbl(l_stat_tbl_ctr).schedule_ship_date := x_line_tbl(i).schedule_arrival_date;
         ELSE
            g_order_lines_stat_tbl(l_stat_tbl_ctr).schedule_ship_date := x_line_tbl(i).schedule_ship_date;
         END IF;

         IF (x_return_status != fnd_api.g_ret_sts_success)
         THEN
            g_order_lines_stat_tbl(l_stat_tbl_ctr).status := 'Error';
            g_order_lines_stat_tbl(l_stat_tbl_ctr).error_message := SUBSTR(REPLACE(l_err_message,CHR(10),' '),1,200);
            x_status := 'Error';
         ELSIF p_line_tbl(i).promise_date IS NULL
         THEN
            g_order_lines_stat_tbl(l_stat_tbl_ctr).status := 'Success';
            g_order_lines_stat_tbl(l_stat_tbl_ctr).error_message := NULL;
         ELSIF     TRUNC(NVL(p_line_tbl(i).schedule_ship_date, SYSDATE + 999)) <> TRUNC(NVL(x_line_tbl(i).schedule_ship_date, SYSDATE + 999))
               AND NVL(p_order_date_type_code, 'SHIP') = 'SHIP'
         THEN
            g_order_lines_stat_tbl(l_stat_tbl_ctr).status := 'Warning';
            g_order_lines_stat_tbl(l_stat_tbl_ctr).error_message :=
                  'Update Successful. But Schedule Ship Date adjusted to new value '
               || 'instead of '
               || TO_CHAR(p_line_tbl(i).schedule_ship_date, 'DD-MON-YYYY');
            x_status := 'Warning';
         ELSIF     TRUNC(NVL(p_line_tbl(i).schedule_arrival_date, SYSDATE + 999)) <> TRUNC(NVL(x_line_tbl(i).schedule_arrival_date, SYSDATE + 999))
               AND NVL(p_order_date_type_code, 'SHIP') = 'ARRIVAL'
         THEN
            g_order_lines_stat_tbl(l_stat_tbl_ctr).status := 'Warning';
            g_order_lines_stat_tbl(l_stat_tbl_ctr).error_message :=
                  'Update Successful. But Schedule Arrival Date adjusted to new value '
               || 'instead of '
               || TO_CHAR(p_line_tbl(i).schedule_arrival_date, 'DD-MON-YYYY');
            x_status := 'Warning';
         ELSE
            g_order_lines_stat_tbl(l_stat_tbl_ctr).status := 'Success';
            g_order_lines_stat_tbl(l_stat_tbl_ctr).error_message := NULL;
         END IF;
      END LOOP;

      wwt_runtime_utilities.DEBUG(1,  'After line table loop x_status = '
                                   || x_status);
      wwt_runtime_utilities.DEBUG(1, 'End call_process_order_api  ');
   EXCEPTION
      WHEN OTHERS
      THEN
         fnd_file.put_line(fnd_file.LOG, 'call_process_order_api WHEN OTHERS EXCEPTION1 '
                            || SQLERRM);
         wwt_runtime_utilities.flush_message_stack;
         RAISE;
   END call_process_order_api;

                                                                              /*
   -----------------------------------------------------------------------------
   | Procedure Name:  main                                                     |
   |                                                                           |
   | Description:  This procedure updates the promise date and schedule ship   |
   |               date on drop ship sales order lines with the associated     |
   |               purchase order line promise date. Update only occurs for    |
   |               po_line_location records created or updated since last      |
   |               successful concurrent request start.                        |
   |                                                                           |
   -----------------------------------------------------------------------------
                                                                              */
   PROCEDURE main(
      x_errbuff                  OUT      VARCHAR2
     ,x_retcode                  OUT      NUMBER
   )
   IS
      l_conc_req_id                 NUMBER;
      l_conc_req_start              DATE;
      l_prev_header_id              NUMBER;
      l_prev_order_number           NUMBER;
      l_prev_buyer_name             wwt_per_all_people_v.full_name%TYPE;
      l_prev_date_type_code         oe_order_headers_all.order_date_type_code%TYPE;
      l_status                      VARCHAR2(10);
      l_line_tbl                    oe_order_pub.line_tbl_type;
      l_ctr                         NUMBER;
      e_last_run_date               EXCEPTION;
      l_complex_prog                NUMBER;
      -- Added for Non shippable Lines
      l_nonship_line_update         wwt_om_cascade_values_to_lines.nonship_line_update_arr;
      l_retcode                     NUMBER := 0;
      l_error_message               VARCHAR2(4000);

      TYPE l_nonship_line_reupdate_rec IS RECORD(
         header_id                     NUMBER
        ,order_number                  VARCHAR2(240)
        ,buyer_name                    VARCHAR2(240)
        ,date_type_code                VARCHAR2(240)
      );

      TYPE l_nonship_line_reupdate_arr IS TABLE OF l_nonship_line_reupdate_rec
         INDEX BY BINARY_INTEGER;

      l_nonship_line_reupdate       l_nonship_line_reupdate_arr;
      l_counter                     NUMBER := 0;
      l_header_already_exists       VARCHAR2(30) := 'N';

      /*
         This cursor selects the Dropship and Non-dropship orders where the
         corresponding PO has been updated since the last tundate of this
         program, and where the promisedate on PO is not same as that on
         the SO.
      */
      CURSOR l_so_lines_cur
      IS
         SELECT   /*+ ORDERED */
                  ooha.header_id
                 ,ooha.order_number
                 ,oola.line_id
                 ,oola.line_number
                 ,0 prom_date_plus_days
                 ,ooha.order_date_type_code
                 ,wpapv.full_name buyer_name
                 ,MAX(TRUNC(plla.promised_date)) promised_date
                 ,wlav.attribute2 line_flow
                 ,0 delivery_lead_time
                 ,plla.attribute4 vendor_commit_to_ship
                 ,ooha.salesrep_id   -- Added for Changes for B-46635 - Complex Prog exclude Promise Date sync -STRY0053562
                 ,NVL(wplld.attribute5, 'N')  otm_visibility_flag    --  STRY0355087  OTM visibility flag
                 ,wplld.attribute2            actual_ship_date        -- STRY0355087  OTM Actual Ship Date
             FROM po_line_locations plla
                 ,po_requisition_lines prla
                 ,wwt_lookups_active_v wlav
                 ,oe_order_lines oola
                 ,oe_order_headers ooha
                 ,per_all_people_f wpapv
                 ,apps.wwt_po_line_locations_dff  wplld
            WHERE plla.line_location_id = prla.line_location_id  -- STRY0355087
              AND wplld.source_key_id_1(+) = plla.line_location_id
              AND TO_CHAR(prla.requisition_line_id) = oola.attribute20
              AND TO_CHAR(oola.line_type_id) = wlav.attribute1
              AND wlav.lookup_type = 'WWT_OM_LINE_FLOW_CONTROLS'
              AND wlav.attribute2 = 'DROP_SHIP'
              AND oola.header_id = ooha.header_id
              AND plla.last_update_date >= l_conc_req_start
              --AND      plla.ship_to_organization_id IN (245, 371, 614, 788, 248)  --CHG12338
              AND plla.quantity != NVL(plla.quantity_cancelled, 0)
              --Line location has not been cancelled
              AND TRUNC(NVL(oola.promise_date, SYSDATE + 99)) <>
                     wwt_ds_so_promise_date_upd_pkg.get_plla_promise_date(wlav.attribute2
                                                                         ,ooha.order_date_type_code
                                                                         ,plla.promised_date
                                                                         ,plla.attribute4
                                                                         )   --Added by hazrab on 03-Jul-2019
              --TRUNC (NVL (plla.promised_date, SYSDATE + 99)) --Commented by hazrab on 03-Jul-2019
              AND oola.open_flag = 'Y'
              AND ooha.attribute8 = wpapv.person_id(+)
              AND SYSDATE BETWEEN wpapv.effective_start_date(+) AND wpapv.effective_end_date(+)
              AND wwt_ds_so_promise_date_upd_pkg.get_reserved_quantity(oola.line_id) = 0
              AND NVL(oola.shipped_quantity, 0) = 0
              AND oola.shippable_flag = 'Y'
              AND plla.quantity !=(  plla.quantity_received + plla.quantity_rejected + plla.quantity_cancelled)   --Do not pick fully received PO
         GROUP BY ooha.header_id
                 ,ooha.order_number
                 ,oola.line_id
                 ,oola.line_number
                 ,ooha.order_date_type_code
                 ,wpapv.full_name
                 ,wlav.attribute2
                 ,plla.attribute4
                 ,ooha.salesrep_id
                 ,wplld.attribute5               -- otm visibility flg  added by thakura for STRY0355087
                 ,wplld.attribute2               -- actual ship date
         UNION ALL
         SELECT   /*+ ORDERED */
                  ooha.header_id
                 ,ooha.order_number
                 ,oola.line_id
                 ,oola.line_number
                 ,
                  --TO_NUMBER (wlav2.attribute3) prom_date_plus_days,     -- CHG24305
                  NVL((SELECT MAX(TO_NUMBER(wlav.attribute3))
                         FROM apps.wwt_lookups_active_v wlav
                        WHERE wlav.lookup_type = 'WWT_SO_PROMISE_DATE_UPDATE'
                          AND wlav.attribute1 = jrs.attribute2
                          AND wlav.attribute5 = jrs.salesrep_id   -- CHG26798
                          AND wlav.attribute4 = hl.country)
                     ,NVL((SELECT MAX(TO_NUMBER(wlav.attribute3))
                             FROM apps.wwt_lookups_active_v wlav
                            WHERE wlav.lookup_type = 'WWT_SO_PROMISE_DATE_UPDATE'
                              AND wlav.attribute1 = jrs.attribute2
                              AND wlav.attribute5 IS NULL
                              AND wlav.attribute4 = hl.country)
                         ,   -- CHG26798
                          NVL((SELECT MAX(TO_NUMBER(wlav.attribute3))
                                 FROM apps.wwt_lookups_active_v wlav
                                WHERE wlav.lookup_type = 'WWT_SO_PROMISE_DATE_UPDATE'
                                  AND wlav.attribute1 = jrs.attribute2
                                  AND wlav.attribute5 = jrs.salesrep_id   -- CHG26798
                                  AND wlav.attribute4 = 'NON US')
                             ,NVL((SELECT MAX(TO_NUMBER(wlav.attribute3))
                                     FROM apps.wwt_lookups_active_v wlav
                                    WHERE wlav.lookup_type = 'WWT_SO_PROMISE_DATE_UPDATE'
                                      AND wlav.attribute1 = jrs.attribute2
                                      AND wlav.attribute5 IS NULL
                                      AND wlav.attribute4 = 'NON US')
                                 ,   -- CHG26798
                                  NVL((SELECT MAX(TO_NUMBER(wlav.attribute3))   --CHG25091
                                         FROM apps.wwt_lookups_active_v wlav
                                        WHERE wlav.lookup_type = 'WWT_SO_PROMISE_DATE_UPDATE'
                                          AND wlav.attribute1 = jrs.attribute2
                                          AND wlav.attribute5 = jrs.salesrep_id
                                          AND wlav.attribute4 = 'ALL')
                                     ,   --CHG26798
                                      NVL((SELECT MAX(TO_NUMBER(wlav.attribute3))   --CHG25091
                                             FROM apps.wwt_lookups_active_v wlav
                                            WHERE wlav.lookup_type = 'WWT_SO_PROMISE_DATE_UPDATE'
                                              AND wlav.attribute1 = jrs.attribute2
                                              AND wlav.attribute5 IS NULL   --CHG26798
                                              AND wlav.attribute4 = 'ALL')
                                         ,0)))))) prom_date_plus_days
                 ,   --CHG24305
                  ooha.order_date_type_code
                 ,wpapv.full_name buyer_name
                 ,MAX(TRUNC(plla.promised_date)) promised_date
                 ,wlav1.attribute2 line_flow
                 ,oola.delivery_lead_time
                 ,plla.attribute4 vendor_commit_to_ship
                 ,ooha.salesrep_id   -- Added for Changes for B-46635 - Complex Prog exclude Promise Date sync -STRY0053562
                 ,NVL(wplld.attribute5, 'N')  otm_visibility_flag    --  STRY0355087  OTM visibility flag
                 ,wplld.attribute2            actual_ship_date        -- STRY0355087  OTM Actual Ship Date
             FROM po_line_locations plla
                 ,po_requisition_lines prla
                 ,oe_order_lines oola
                 ,oe_order_headers ooha
                 ,jtf_rs_salesreps jrs
                  --wwt_lookups_active_v wlav2,                                         -- CHG24305
                 ,wwt_lookups_active_v wlav1
                 ,per_all_people_f wpapv
                  -- Ship To Tables
                 ,hz_cust_site_uses hcsu -- CHG24305
                 ,hz_cust_acct_sites hcas -- CHG24305
                 ,hz_party_sites hps -- CHG24305
                 ,hz_locations hl   -- CHG24305
                 ,apps.wwt_po_line_locations_dff  wplld
            WHERE plla.last_update_date >= l_conc_req_start
              AND wplld.source_key_id_1(+) = plla.line_location_id  --STRY0355087
              AND plla.quantity != NVL(plla.quantity_cancelled, 0) --Line location has not been cancelled
              AND plla.line_location_id = prla.line_location_id
              AND oola.attribute20 = TO_CHAR(prla.requisition_line_id)
              AND oola.open_flag = 'Y'   --SO line is not Closed
              AND TRUNC(NVL(oola.promise_date, SYSDATE + 99)) <> TRUNC(NVL(plla.promised_date, SYSDATE + 99))
              AND oola.header_id = ooha.header_id
              AND ooha.salesrep_id = jrs.salesrep_id
              AND ooha.org_id = jrs.org_id
              AND oola.ship_to_org_id = hcsu.site_use_id   -- CHG24305
              AND hcsu.cust_acct_site_id = hcas.cust_acct_site_id   -- CHG24305
              AND hcas.party_site_id = hps.party_site_id   -- CHG24305
              AND hps.location_id = hl.location_id   -- CHG24305
              --AND      wlav2.lookup_type = 'WWT_SO_PROMISE_DATE_UPDATE'                   -- CHG24305
              --AND      jrs.attribute2 = wlav2.attribute1 -- Program ID                    -- CHG24305
              AND TO_CHAR(oola.line_type_id) = wlav1.attribute1
              AND wlav1.lookup_type = 'WWT_OM_LINE_FLOW_CONTROLS'
              AND wlav1.attribute2 = 'OE_TO_PO'
              AND ooha.attribute8 = wpapv.person_id(+)
              AND SYSDATE BETWEEN wpapv.effective_start_date(+) AND wpapv.effective_end_date(+)
              AND wwt_ds_so_promise_date_upd_pkg.get_reserved_quantity(oola.line_id) = 0
              AND NVL(oola.shipped_quantity, 0) = 0
              AND oola.shippable_flag = 'Y'
              AND EXISTS(
                     SELECT 1
                       FROM wwt_lookups_active_v wlav2
                      WHERE wlav2.lookup_type = 'WWT_SO_PROMISE_DATE_UPDATE'
                        AND jrs.attribute2 = wlav2.attribute1   -- Program ID
                        AND jrs.salesrep_id = NVL(wlav2.attribute5, jrs.salesrep_id)   -- Salesrep ID
                                                                                    )   -- CHG25091
              AND plla.quantity !=(  plla.quantity_received + plla.quantity_rejected + plla.quantity_cancelled)   --Do not pick fully received PO
         GROUP BY ooha.header_id
                 ,ooha.order_number
                 ,oola.line_id
                 ,oola.line_number
                 ,ooha.order_date_type_code
                 ,jrs.attribute2   -- CHG24305
                 ,jrs.salesrep_id   -- CHG26798
                 ,hl.country   -- CHG24305
                 --TO_NUMBER (wlav2.attribute3),-- CHG24305
         ,        wpapv.full_name
                 ,wlav1.attribute2
                 ,oola.delivery_lead_time
                 ,plla.attribute4
                 ,ooha.salesrep_id
                 ,wplld.attribute5               -- otm visibility flg  added by thakura for STRY0355087
                 ,wplld.attribute2               -- actual ship date
         ORDER BY 1
                 ,2
                 ,4;
   BEGIN
      fnd_file.put_line(fnd_file.LOG, 'Begin main ');
      /*l_conc_req_id := fnd_global.conc_request_id;
      --Determines the concurrent request ID for the current session
      fnd_file.put_line (fnd_file.log, 'REQUEST_ID: ' || l_conc_req_id);

      BEGIN
         l_conc_req_start :=  NVL (wwt_parent_conc_req_date (l_conc_req_id, 'START'),
                                   TRUNC (SYSDATE));
      EXCEPTION
         WHEN OTHERS THEN
            fnd_file.put_line (fnd_file.log, '10: Error occurred in main: '|| SQLERRM);
      END;*/
      fnd_file.put_line(fnd_file.LOG, 'org_id : '
                         || g_org_id);
      -- Get Last Request Run Date
      get_last_run_date(x_last_run_date          => l_conc_req_start, x_status => l_status);

      IF l_status = 'E'
      THEN
         fnd_file.put_line(fnd_file.LOG, 'Error while deriving Last Concurrent Request Run Date.');
         RAISE e_last_run_date;
      ELSE
         fnd_file.put_line(fnd_file.LOG, 'Last concurrent request start date/time: ' || TO_CHAR(l_conc_req_start, 'DD-MON-YYYY HH24:MI:SS'));
      END IF;

      -- Set Last Request Run Date to sysdate
      set_last_run_date(p_last_run_date          => SYSDATE, x_status => l_status);

      IF l_status = 'E'
      THEN
         fnd_file.put_line(fnd_file.LOG, 'Error while Updating Last Concurrent Request Run Date.');
         RAISE e_last_run_date;
      END IF;

      l_line_tbl := oe_order_pub.g_miss_line_tbl;
      l_ctr := 0;

      FOR l_so_lines_rec IN l_so_lines_cur
      LOOP   --Opening Cursor l_so_lines_cur
         -- Update sales order with PO Promise Date
         fnd_file.put_line(fnd_file.LOG
                          ,    'header_id = '
                            || l_so_lines_rec.header_id
                            || ' line_id = '
                            || l_so_lines_rec.line_id
                            || ' prom_date_plus_days = '
                            || l_so_lines_rec.prom_date_plus_days
                            || ' promised_date = '
                            || l_so_lines_rec.promised_date
                            || 'vendor commit to ship = '
                            || l_so_lines_rec.vendor_commit_to_ship);

         /*BEGIN
            UPDATE apps.oe_order_lines_all
            SET promise_date = l_so_lines_rec.promised_date,
                               + l_so_lines_rec.prom_date_plus_days
                last_update_date = SYSDATE,
                last_updated_by = 0
            WHERE  line_id = l_so_lines_rec.line_id;
         EXCEPTION
            WHEN OTHERS THEN
               DBMS_OUTPUT.put_line
                       ('20: Error occurred in WWT_DS_SO_PROMISE_DATE_UPDATE: '
                        || SQLERRM);
         END;*/

         -- Call API instead of direct update, CHG12338
         /* Populate Line table for a Order Header, and call process_order API
            to update all lines for the order.
            Flow: a) Populate lines table for every record in loop.
                  b) When Order is changed, call process order api.
                  c) Call api again after the loop as last order is left unprocessed.
         */
         IF NVL(l_prev_header_id, -1) <> l_so_lines_rec.header_id
         THEN
            IF l_ctr > 0
            THEN
               fnd_file.put_line(fnd_file.LOG, 'Calling process_order api, header_id = '
                                  || l_prev_header_id);
               --Call API
               call_process_order_api(p_line_tbl               => l_line_tbl
                                     ,p_order_number           => l_prev_order_number
                                     ,p_buyer_name             => l_prev_buyer_name
                                     ,p_order_date_type_code   => l_prev_date_type_code
                                     ,x_status                 => l_status
                                     );

               IF l_status IN('Error', 'Warning')
               THEN
                  x_retcode := 1;
               END IF;

               -- Re-initialize lines table
               l_ctr := 0;
               l_line_tbl.DELETE;
               l_line_tbl := oe_order_pub.g_miss_line_tbl;
            END IF;
         END IF;
      /* Start of  Commenting Complex Prog Feature version 3.0 Chnages  *//*
         -- Start Changes for B-46635 - Complex Prog exclude Promise Date sync -STRY0053562
         SELECT COUNT(1)
           INTO l_complex_prog
           FROM apps.wwt_lookups_active_v wla
          WHERE wla.lookup_type = 'WWT_COMPLEX_PROG_SALES_CHANNEL'
            AND wwt_util_datatypes_pkg.wwt_to_number(wla.attribute1) = l_so_lines_rec.salesrep_id;

          -- End Changes for B-46635 - Complex Prog exclude Promise Date sync -STRY0053562
      */ /* End of  Commenting Complex Prog Feature version 3.0 Chnages  */
         -- Populate Line table
         l_ctr :=   l_ctr + 1;
         l_line_tbl(l_ctr) := oe_order_pub.g_miss_line_rec;
         l_line_tbl(l_ctr).header_id := l_so_lines_rec.header_id;
         l_line_tbl(l_ctr).line_id := l_so_lines_rec.line_id;
         l_line_tbl(l_ctr).line_number := l_so_lines_rec.line_number;
         l_line_tbl(l_ctr).operation := oe_globals.g_opr_update;

         --         l_line_tbl (l_ctr).promise_date := l_so_lines_rec.promised_date;
         --
         --         -- Update Schedule Date only when Promise Date on PO has some value
         --         IF l_so_lines_rec.promised_date IS NOT NULL THEN
         --            IF l_so_lines_rec.order_date_type_code = 'ARRIVAL' THEN
         --               l_line_tbl (l_ctr).schedule_arrival_date := l_so_lines_rec.promised_date
         --                                                         + l_so_lines_rec.prom_date_plus_days;
         --            ELSE
         --               l_line_tbl (l_ctr).schedule_ship_date := l_so_lines_rec.promised_date
         --                                                         + l_so_lines_rec.prom_date_plus_days;
         --            END IF;
         --         END IF;
         IF l_so_lines_rec.line_flow = 'DROP_SHIP'
         THEN
            IF l_so_lines_rec.promised_date IS NOT NULL
            THEN
               IF l_so_lines_rec.order_date_type_code = 'ARRIVAL'
               THEN
                  /* Start of  Commenting Complex Prog Feature version 3.0 Chnages  *//*
                  IF l_complex_prog = 0
                  THEN
                     --Added for B-46635 - Complex Prog exclude Promise Date sync -STRY0053562
                     l_line_tbl(l_ctr).promise_date := l_so_lines_rec.promised_date;
                  END IF;
                   */ /* End of  Commenting Complex Prog Feature version 3.0 Chnages  */

                  IF NOT wwt_om_cascade_values_to_lines.is_non_shippable(l_so_lines_rec.line_id)
                  THEN   -- Added by Selvan for Non Ship SSD Recalculation
                     l_line_tbl(l_ctr).schedule_arrival_date := l_so_lines_rec.promised_date;
                  END IF;
               ELSE
                  /* Start of  Commenting Complex Prog Feature version 3.0 Chnages  *//*
                  IF l_complex_prog = 0
                  THEN   --Added for B-46635 - Complex Prog exclude Promise Date sync -STRY0053562
                     l_line_tbl(l_ctr).promise_date :=
                                     NVL(TRUNC(TO_DATE(l_so_lines_rec.vendor_commit_to_ship, 'YYYY/MM/DD HH24:MI:SS')), l_so_lines_rec.promised_date);
                  END IF;
                  */ /* End of  Commenting Complex Prog Feature version 3.0 Chnages  */
                  IF NOT wwt_om_cascade_values_to_lines.is_non_shippable(l_so_lines_rec.line_id)
                  THEN   -- Added by Selvan for Non Ship SSD Recalculation
                     ---STRY0355087 Assigning actual ship date from OTM to SSD[schedule_ship_date] in Sales Order lines using the associated PO line's having OTM enabled flag as Y when VCS and PD are NULL                 
                     l_line_tbl(l_ctr).schedule_ship_date :=   CASE l_so_lines_rec.otm_visibility_flag
                                                                  WHEN 'Y' THEN  -- for OTM enabled po lines
                                                                        CASE
                                                                           WHEN l_so_lines_rec.actual_ship_date IS NOT NULL
                                                                                THEN TRUNC(TO_DATE(l_so_lines_rec.actual_ship_date,    'YYYY/MM/DD HH24:MI:SS'))
                                                                           WHEN l_so_lines_rec.promised_date IS NOT NULL
                                                                                THEN l_so_lines_rec.promised_date
                                                                           ELSE NULL
                                                                        END
                                                                  ELSE     -- 'N' or anything else
                                                                        CASE
                                                                           WHEN l_so_lines_rec.vendor_commit_to_ship IS NOT NULL
                                                                                THEN TRUNC(TO_DATE(l_so_lines_rec.vendor_commit_to_ship,'YYYY/MM/DD HH24:MI:SS'))
                                                                           WHEN l_so_lines_rec.promised_date IS NOT NULL
                                                                                THEN l_so_lines_rec.promised_date
                                                                           ELSE NULL
                                                                        END
                                                               END;
                  END IF;
               END IF;
            END IF;
         END IF;

         IF l_so_lines_rec.line_flow = 'OE_TO_PO'
         THEN
            IF l_so_lines_rec.promised_date IS NOT NULL
            THEN
               IF l_so_lines_rec.order_date_type_code = 'ARRIVAL'
               THEN
                   /* Start of  Commenting Complex Prog Feature version 3.0 Chnages  *//*
                  IF l_complex_prog = 0
                  THEN   --Added for B-46635 - Complex Prog exclude Promise Date sync -STRY0053562
                     l_line_tbl(l_ctr).promise_date :=
                                                  l_so_lines_rec.promised_date
                                                + l_so_lines_rec.prom_date_plus_days
                                                + l_so_lines_rec.delivery_lead_time;
                  END IF;
                   */ /* End of  Commenting Complex Prog Feature version 3.0 Chnages  */
                  IF NOT wwt_om_cascade_values_to_lines.is_non_shippable(l_so_lines_rec.line_id)
                  THEN   -- Added If Clause for STRY0124130 : Non Ship SSD Recalculation
                     l_line_tbl(l_ctr).schedule_arrival_date :=
                                                  l_so_lines_rec.promised_date
                                                + l_so_lines_rec.prom_date_plus_days
                                                + l_so_lines_rec.delivery_lead_time;
                  END IF;
               ELSE
                   /* Start of  Commenting Complex Prog Feature version 3.0 Chnages  *//*
                  IF l_complex_prog = 0
                  THEN   --Added for B-46635 - Complex Prog exclude Promise Date sync -STRY0053562
                     l_line_tbl(l_ctr).promise_date :=   l_so_lines_rec.promised_date
                                                       + l_so_lines_rec.prom_date_plus_days;
                  END IF;
                   */ /* End of  Commenting Complex Prog Feature version 3.0 Chnages  */
                  IF NOT wwt_om_cascade_values_to_lines.is_non_shippable(l_so_lines_rec.line_id)
                  THEN   -- Added If Clause for STRY0124130 : Non Ship SSD Recalculation
                     l_line_tbl(l_ctr).schedule_ship_date :=   l_so_lines_rec.promised_date
                                                             + l_so_lines_rec.prom_date_plus_days;
                  END IF;
               END IF;
            END IF;
         END IF;

         -- Start : Added for STRY0124130 : Non Ship SSD Recalculation
         IF wwt_om_cascade_values_to_lines.is_nonship_exists(l_so_lines_rec.header_id)
         THEN
            l_header_already_exists := 'N';

            IF l_counter > 0
            THEN
               FOR cntr IN 1 .. l_counter
               LOOP
                  IF l_nonship_line_reupdate(cntr).header_id = l_so_lines_rec.header_id
                  THEN
                     l_header_already_exists := 'Y';
                  END IF;
               END LOOP;
            END IF;

            IF l_header_already_exists = 'N'
            THEN
               l_counter :=   l_counter + 1;
               l_nonship_line_reupdate(l_counter).header_id := l_so_lines_rec.header_id;
               l_nonship_line_reupdate(l_counter).order_number := l_so_lines_rec.order_number;
               l_nonship_line_reupdate(l_counter).buyer_name := l_so_lines_rec.buyer_name;
               l_nonship_line_reupdate(l_counter).date_type_code := l_so_lines_rec.order_date_type_code;
            END IF;
         END IF;
         -- End : Added for STRY0124130 : Non Ship SSD Recalculation

         -- Keep order header_id and number
         l_prev_header_id := l_so_lines_rec.header_id;
         l_prev_order_number := l_so_lines_rec.order_number;
         l_prev_buyer_name := l_so_lines_rec.buyer_name;
         l_prev_date_type_code := l_so_lines_rec.order_date_type_code;
      END LOOP;   -- END CURSOR

      -- Process Last Order
      IF l_ctr > 0
      THEN
         fnd_file.put_line(fnd_file.LOG, 'Calling process_order api, header_id = '
                            || l_prev_header_id
                            || ' order# = '
                            || l_prev_order_number);
         -- Call API
         call_process_order_api(p_line_tbl               => l_line_tbl
                               ,p_order_number           => l_prev_order_number
                               ,p_buyer_name             => l_prev_buyer_name
                               ,p_order_date_type_code   => l_prev_date_type_code
                               ,x_status                 => l_status
                               );
         fnd_file.put_line(fnd_file.LOG, 'Return Status = '
                            || l_status);

         IF l_status IN('Error', 'Warning')
         THEN
            x_retcode := 1;
         END IF;
      END IF;

      -- commit work
      COMMIT;

      -- Start : Added for STRY0124130 : Non Ship SSD Recalculation
      IF l_nonship_line_reupdate.COUNT > 0
      THEN
         FOR i IN 1 .. l_nonship_line_reupdate.LAST
         LOOP
            l_ctr := 0;
            l_line_tbl.DELETE;
            l_line_tbl := oe_order_pub.g_miss_line_tbl;
            l_nonship_line_update := wwt_om_cascade_values_to_lines.nonship_line_update_arr();
            wwt_om_cascade_values_to_lines.fetch_nonship_line_sch_date(p_header_id              => l_nonship_line_reupdate(i).header_id
                                                                      ,p_nonship_line_update    => l_nonship_line_update
                                                                      ,p_ret_status             => l_retcode
                                                                      ,p_error_msg              => l_error_message
                                                                      );

            IF l_nonship_line_update.COUNT > 0
            THEN
               FOR j IN 1 .. l_nonship_line_update.LAST
               LOOP
                  l_ctr :=   l_ctr + 1;
                  l_line_tbl(l_ctr) := oe_order_pub.g_miss_line_rec;
                  l_line_tbl(l_ctr).header_id := l_nonship_line_update(j).header_id;
                  l_line_tbl(l_ctr).line_id := l_nonship_line_update(j).line_id;
                  l_line_tbl(l_ctr).line_number := l_nonship_line_update(j).line_number;
                  l_line_tbl(l_ctr).operation := oe_globals.g_opr_update;

                  IF l_nonship_line_reupdate(i).date_type_code = 'SHIP'
                  THEN
                     l_line_tbl(l_ctr).schedule_ship_date := l_nonship_line_update(j).schedule_ship_date;
                  ELSE
                     l_line_tbl(l_ctr).schedule_arrival_date := l_nonship_line_update(j).schedule_arrival_date;
                  END IF;
               END LOOP;
            END IF;

            --
            -- Call Process Order API
            --
            call_process_order_api(p_line_tbl               => l_line_tbl
                                  ,p_order_number           => l_nonship_line_reupdate(i).order_number
                                  ,p_buyer_name             => l_nonship_line_reupdate(i).buyer_name
                                  ,p_order_date_type_code   => l_nonship_line_reupdate(i).date_type_code
                                  ,x_status                 => l_status
                                  );
            fnd_file.put_line(fnd_file.LOG, 'Return Status = '
                               || l_status);
         END LOOP;
      END IF;

      -- End : Added for STRY0124130 : Non Ship SSD Recalculation

      -- Print the details of successful updates
      print_details(p_status                 => 'Success');
      -- Print the details of error/warning in updates
      print_details(p_status                 => 'Error');
      fnd_file.put_line(fnd_file.LOG, 'End main');
   EXCEPTION
      WHEN e_last_run_date
      THEN
         x_retcode := 2;
         fnd_file.put_line(fnd_file.LOG, 'main EXCEPTION1, Error in Lookup for Last Run Date.');
         wwt_runtime_utilities.flush_message_stack;
      WHEN OTHERS
      THEN
         x_retcode := 2;
         -- Reset Last Request Run Date to existing date in case of error of the program
         set_last_run_date(p_last_run_date          => l_conc_req_start, x_status => l_status);
         fnd_file.put_line(fnd_file.LOG, 'main WHEN OTHERS EXCEPTION2 '
                            || SQLERRM);
         wwt_runtime_utilities.flush_message_stack;
   END main;
END wwt_ds_so_promise_date_upd_pkg;
/
