# GAC public merchandise preview

Public navigation: /#merch. Public guest cart in the header, no member account required. Shirt photo supplied by owner. Starting example price $30, sizes S/M/L/XL/2XL/3XL; owner can change these.

Owner account: Admin > Merch. Edit name, description, price, sizes/options, image URL and public visibility; add new products. Products without sizes can use One size. Hidden products remain owner-visible but are absent from the public catalog and removed from guest carts on refresh. Quantity selector is per-cart and does not represent stock.

Catalog in public.gac_merch_products with RLS enabled. Public users read only published products; authenticated private owners may read/write all. Owner identity uses existing private owner function, never user metadata. No other member/order/recognition schema is changed.

Cart stores product ID, size and quantity in localStorage only; no identity, address, payment or card details. Product names and prices are loaded afresh from catalog. Cached/client prices are ignored; any future checkout must calculate server-side again. Quantities 1–99 per size. Same product/size merges, separate sizes stay separate. Visitors can update/remove/clear items. Storage failures fall back to memory with notice. Totals exclude shipping/taxes. No stock reservation, payment request, paid status, order creation or fulfillment in this preview. Checkout disabled and labeled coming soon.

Tests: 66 Node checks pass, including cart merge/validation/current pricing; rollback SQL confirmed public read, anonymous/member writes denied, owner edits permitted and rolled back. Security advisors reported no catalog-specific warning. DOM interaction checks passed for public product display, adding/updating/removing cart items, owner-only editor loading and saving a changed price. Browser visual QA unavailable in this environment; static layout and module checks performed. No live payment tests or payment settings changed for merchandise.
