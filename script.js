const menuButton = document.querySelector('.menu-toggle');
const navigation = document.querySelector('.site-nav');

menuButton?.addEventListener('click', () => {
  const isOpen = navigation.classList.toggle('open');
  menuButton.setAttribute('aria-expanded', String(isOpen));
});

document.querySelectorAll('.site-nav a').forEach((link) => {
  link.addEventListener('click', () => {
    navigation.classList.remove('open');
    menuButton?.setAttribute('aria-expanded', 'false');
  });
});

document.getElementById('year').textContent = new Date().getFullYear();

const contactForm = document.getElementById('contact-form');
contactForm?.addEventListener('submit', (event) => {
  event.preventDefault();

  const formData = new FormData(contactForm);
  const name = String(formData.get('name') || '').trim();
  const email = String(formData.get('email') || '').trim();
  const destination = String(formData.get('department') || 'info@gacfirearms.com');
  const message = String(formData.get('message') || '').trim();
  const departmentName = contactForm.querySelector('select[name="department"] option:checked')?.textContent || 'Website Inquiry';

  const subject = encodeURIComponent(`${departmentName} from ${name}`);
  const body = encodeURIComponent(`Name: ${name}\nEmail: ${email}\nInquiry: ${departmentName}\n\n${message}`);

  window.location.href = `mailto:${destination}?subject=${subject}&body=${body}`;
});
