begin;
select cron.schedule('gac-payment-recovery','*/5 * * * *','select gac_private.invoke_payment_recovery()');
commit;
